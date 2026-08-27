#!/usr/bin/env bash
# What the reviewer SAID versus what it merely READ. opencode's terminal
# transcript mixes the two, and no grep can separate them: on 2026-08-20 this
# repo was the review target, the model reported nothing at all, and the old
# reader handed the judge two "findings" that were comments inside
# scripts/ask.sh itself. The JSON event stream keeps them apart --
# `text` is the model talking, `tool_use` is the model working -- and this
# checks that separation holds, including on the fallback paths.
#
#   bash scripts/test-opencode-answer.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# stub: emits json events like `opencode run --format json` does, including a
# tool_use whose output contains a finding-shaped line (a file it "read")
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "${MODE:-normal}" in
  legacy)  echo "> build - deepseek"; echo "src/x.py:1 | HIGH | plain text output, no json" ;;
  error)   echo '{"type":"error","timestamp":1000,"error":{"data":{"message":"rate limited by provider"}}}' ;;
  error_fallback) if [ "$model" = primary ]; then
                    echo '{"type":"error","timestamp":1000,"error":{"data":{"message":"invalid primary model"}}}'
                  else
                    echo '{"type":"step_start","timestamp":1000,"part":{}}'
                  fi ;;
  silent)  echo '{"type":"step_start","timestamp":1000,"part":{}}'
           echo '{"type":"tool_use","timestamp":1200,"part":{"tool":"read","state":{"status":"completed","input":{"filePath":"/repo/scripts/ask.sh"},"output":"# Findings look like: path/file.py:12 | HIGH | why"}}}' ;;
  fallback) if [ "$model" = primary ]; then
              echo '{"type":"step_start","timestamp":1000,"part":{}}'
              echo '{"type":"tool_use","timestamp":1200,"part":{"tool":"read","state":{"status":"completed","input":{"filePath":"/repo/scripts/ask.sh"}}}}'
            else
              echo '{"type":"text","timestamp":1600,"part":{"text":"scripts/ask.sh:177 | MEDIUM | fallback finding"}}'
            fi ;;
  *)       echo '{"type":"step_start","timestamp":1000,"part":{}}'
           echo '{"type":"tool_use","timestamp":1200,"part":{"tool":"read","state":{"status":"completed","input":{"filePath":"/repo/scripts/ask.sh"},"output":"src/other.py:99 | HIGH | this line is inside a file, not an answer"}}}'
           echo '{"type":"tool_use","timestamp":1400,"part":{"tool":"bash","state":{"status":"error","input":{"command":"git diff main...HEAD"}}}}'
           echo '{"type":"text","timestamp":1600,"part":{"text":"scripts/ask.sh:159 | HIGH | the real finding"}}' ;;
esac
STUB
chmod +x "$TMP/bin/opencode"
export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/h"

# No python here means the JSON reader cannot run and every case below would
# be testing the raw-capture fallback instead. Say so rather than fail.
. "$TREE/scripts/providers.sh"
if ! multi_python >/dev/null; then
  echo "  skip — no working python on this machine; the JSON reader cannot run here"
  echo "ALL PASS"; exit 0
fi
PY="$(multi_python)"

echo "== an error event explains a run with no answer =="
printf '%s\n' '{"type":"error","timestamp":1000,"error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details.","ref":"err_47fb8a13"}}}' > "$TMP/error.jsonl"
"$PY" "$TREE/scripts/opencode-report.py" "$TMP/error.jsonl" > "$TMP/error.out" 2> "$TMP/error.err"
error_rc=$?
say "error-only stream is still no-answer" "$error_rc" "3"
say "provider error reaches stderr" "$(grep -c 'Unexpected server error' "$TMP/error.err")" "1"

MODE=error bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/error-run" >/dev/null 2>&1
say "provider error reaches NO ANSWER" "$(grep -c 'rate limited by provider' "$TMP/error-run-opencode.txt")" "1"
say "provider error reaches dead reason" "$(grep -c 'rate limited by provider' "$TMP/error-run-opencode.txt.dead")" "1"
say "specific error replaces generic silence" "$(grep -c 'it ran but said nothing' "$TMP/error-run-opencode.txt")" "0"

MODE=error_fallback bash "$TREE/scripts/ask.sh" --question q --backend opencode --model primary --fallback backup --out-prefix "$TMP/error-chain" >/dev/null 2>&1
say "earlier provider error survives exhausted chain" "$(grep -c 'invalid primary model' "$TMP/error-chain-opencode.txt.dead")" "1"

echo "== the answer is the answer; the files it read are not =="
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/a" >/dev/null 2>&1
say "real finding kept"          "$(grep -c 'the real finding' "$TMP/a-opencode.txt")" "1"
say "file content is not a finding" "$(grep -c 'not an answer' "$TMP/a-opencode.txt")" "0"
say "what it read is listed"     "$(grep -c 'read.*scripts/ask.sh' "$TMP/a-opencode.txt")" "1"
say "failed call is marked"      "$(grep -c 'error' "$TMP/a-opencode.txt")" "1"

echo "== a reviewer that answered nothing says so =="
MODE=silent bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/b" >/dev/null 2>&1
rc=$?
say "single-model NO ANSWER is exact" "$(head -1 "$TMP/b-opencode.txt")" "opencode: NO ANSWER — model=m exit=0 — it ran but said nothing; what it did is in $TMP/b-opencode.txt.calls"
say "single model is not called a chain" "$(grep -c 'FALLBACK CHAIN EXHAUSTED' "$TMP/b-opencode.txt")" "0"
say "nothing passes as a finding" "$(grep -cE '^[^|]*:[0-9]+[^|]*\| *(HIGH|MEDIUM|LOW) *\|' "$TMP/b-opencode.txt")" "0"
say "no-answer is not counted alive" "$rc" "1"

echo "== a real fallback chain says it was exhausted =="
MODE=silent bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --fallback backup --out-prefix "$TMP/e" >/dev/null 2>&1
say "chain exhaustion is explicit" "$(grep -c 'FALLBACK CHAIN EXHAUSTED — tried m,backup' "$TMP/e-opencode.txt")" "1"
say "exhausted chain keeps calls pointer" "$(grep -c "what it did is in $TMP/e-opencode.txt.calls" "$TMP/e-opencode.txt")" "1"

echo "== a no-answer retries once on the fallback model =="
MODE=fallback bash "$TREE/scripts/ask.sh" --question q --backend opencode --model primary --fallback backup --out-prefix "$TMP/f" >/dev/null 2>&1
say "fallback answer kept"       "$(grep -c 'fallback finding' "$TMP/f-opencode.txt")" "1"
say "full swap banner pinned to line 1" "$(sed -n 1p "$TMP/f-opencode.txt" | grep -c 'primary produced no answer — fell back to backup')" "1"
say "first raw capture kept"     "$([ -s "$TMP/f-opencode.txt.jsonl.first" ] && echo yes || echo no)" "yes"
say "first capture has no answer" "$(grep -c 'tool_use' "$TMP/f-opencode.txt.jsonl.first")" "1"
say "fallback calls do not inherit primary calls" "$([ ! -s "$TMP/f-opencode.txt.calls" ] && echo yes || echo no)" "yes"

echo "== an opencode without --format json still gives something usable =="
MODE=legacy bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/c" >/dev/null 2>&1
say "says raw capture"           "$(grep -c 'RAW CAPTURE ONLY' "$TMP/c-opencode.txt")" "1"
say "raw answer retained"        "$(grep -c 'plain text output, no json' "$TMP/c-opencode.txt")" "1"
say "raw lines prefixed"         "$(grep -c '^raw| ' "$TMP/c-opencode.txt")" "2"
say "nothing passes as a finding" "$(grep -cE '^[^|]*:[0-9]+[^|]*\| *(HIGH|MEDIUM|LOW) *\|' "$TMP/c-opencode.txt")" "0"
say "raw capture is live"        "$([ ! -e "$TMP/c-opencode.txt.dead" ] && echo yes || echo no)" "yes"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
