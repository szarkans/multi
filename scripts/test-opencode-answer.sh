#!/usr/bin/env bash
# The transcript is not the answer. OpenCode echoes every file it opens, so a
# comment or a line inside a reviewed file can look exactly like a finding --
# measured on 2026-08-20, when this repo was the target: the model returned no
# findings at all and the parser handed the judge two lines lifted out of
# scripts/review-opencode.sh itself. The model now marks its answer with a
# token minted per run, and only what sits between those markers is parsed.
#
#   bash scripts/test-answer-markers.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# The stub reads the markers out of the prompt it was handed, like the model would.
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
prompt="${!#}"
b="$(printf '%s\n' "$prompt" | grep -o 'MULTI-FINDINGS-[0-9]*-BEGIN' | head -1)"
e="$(printf '%s\n' "$prompt" | grep -o 'MULTI-FINDINGS-[0-9]*-END' | head -1)"
# transcript noise first: this is what reading a source file looks like
echo "> build - deepseek"
echo "cat scripts/review-opencode.sh"
echo "# Findings look like: path/file.py:12 | HIGH | why"
echo "src/other.py:99 | HIGH | this line lives inside a file the model read"
case "${MODE:-normal}" in
  nomarkers) exit 0 ;;
  clean)     printf '%s\nNo issues found\n%s\n' "$b" "$e" ;;
  *)         printf '%s\nsrc/app.py:12 | HIGH | the real finding\nand a sentence that is not a finding line\n%s\n' "$b" "$e" ;;
esac
STUB
chmod +x "$TMP/bin/opencode"
export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/h"

echo "== transcript noise must not become findings =="
bash "$TREE/scripts/review-opencode.sh" --target t --model m --out "$TMP/a.txt" >/dev/null 2>&1
say "real finding kept"        "$(grep -c 'the real finding' "$TMP/a.txt")" "1"
say "file content NOT a finding" "$(grep -c 'inside a file the model read' "$TMP/a.txt")" "0"
say "own comment NOT a finding"  "$(grep -c 'Findings look like' "$TMP/a.txt")" "0"
say "off-format line counted"    "$(grep -c 'were not in finding format' "$TMP/a.txt")" "1"

echo "== a clean verdict still works =="
MODE=clean bash "$TREE/scripts/review-opencode.sh" --target t --model m --out "$TMP/b.txt" >/dev/null 2>&1
say "reads as clean" "$(head -1 "$TMP/b.txt")" "No issues found."

echo "== no markers at all is reported, not parsed out of the transcript =="
MODE=nomarkers bash "$TREE/scripts/review-opencode.sh" --target t --model m --out "$TMP/c.txt" >/dev/null 2>&1
say "says no marked answer" "$(grep -c 'NO MARKED ANSWER' "$TMP/c.txt")" "1"
say "nothing in it can pass as a finding" "$(grep -cE '^[^|]*:[0-9]+[^|]*\| *(HIGH|MEDIUM|LOW) *\|' "$TMP/c.txt")" "0"
say "transcript lines are prefixed" "$(grep -c '^raw| ' "$TMP/c.txt" | awk '{print ($1>0)?"yes":"no"}')" "yes"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
