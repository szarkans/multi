#!/usr/bin/env bash
# What the reviewer SAID versus what it merely READ. opencode's terminal
# transcript mixes the two, and no grep can separate them: on 2026-08-20 this
# repo was the review target, the model reported nothing at all, and the old
# reader handed the judge two "findings" that were comments inside
# scripts/review-opencode.sh itself. The JSON event stream keeps them apart --
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
case "${MODE:-normal}" in
  legacy)  echo "> build - deepseek"; echo "src/x.py:1 | HIGH | plain text output, no json" ;;
  silent)  echo '{"type":"step_start","timestamp":1000,"part":{}}'
           echo '{"type":"tool_use","timestamp":1200,"part":{"tool":"read","state":{"status":"completed","input":{"filePath":"/repo/scripts/review-opencode.sh"},"output":"# Findings look like: path/file.py:12 | HIGH | why"}}}' ;;
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

echo "== the answer is the answer; the files it read are not =="
bash "$TREE/scripts/review-opencode.sh" --target t --model m --out "$TMP/a.txt" >/dev/null 2>&1
say "real finding kept"          "$(grep -c 'the real finding' "$TMP/a.txt")" "1"
say "file content is not a finding" "$(grep -c 'not an answer' "$TMP/a.txt")" "0"
say "what it read is listed"     "$(grep -c 'read.*scripts/ask.sh' "$TMP/a.txt")" "1"
say "failed call is marked"      "$(grep -c 'error' "$TMP/a.txt")" "1"

echo "== a reviewer that answered nothing says so =="
MODE=silent bash "$TREE/scripts/review-opencode.sh" --target t --model m --out "$TMP/b.txt" >/dev/null 2>&1
say "says NO ANSWER"             "$(grep -c 'NO ANSWER' "$TMP/b.txt")" "1"
say "nothing passes as a finding" "$(grep -cE '^[^|]*:[0-9]+[^|]*\| *(HIGH|MEDIUM|LOW) *\|' "$TMP/b.txt")" "0"

echo "== an opencode without --format json still gives something usable =="
MODE=legacy bash "$TREE/scripts/review-opencode.sh" --target t --model m --out "$TMP/c.txt" >/dev/null 2>&1
say "says raw capture"           "$(grep -c 'RAW CAPTURE ONLY' "$TMP/c.txt")" "1"
say "raw lines prefixed"         "$(grep -c '^raw| ' "$TMP/c.txt")" "2"
say "nothing passes as a finding" "$(grep -cE '^[^|]*:[0-9]+[^|]*\| *(HIGH|MEDIUM|LOW) *\|' "$TMP/c.txt")" "0"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
