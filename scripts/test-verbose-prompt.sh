#!/usr/bin/env bash
# The probe is the sole config reader for prompt previews. Fake interpreters
# reproduce the Windows Store stub: junk on stdout and a successful exit.
# No model backend is called.
#
#   bash scripts/test-verbose-prompt.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/h"
export MULTI_HOME="$TMP/h" MULTI_PROVIDERS_ENV="$TMP/no-providers.env"
unset MULTI_CONFIG VERBOSE_TEST_KEY
real_py="$(. "$TREE/scripts/providers.sh"; multi_python)"
real_py="$(command -v "$real_py")"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
config() {
  cat > "$MULTI_HOME/config.toml" <<'EOF'
default_profile = "p"
[backends.test]
type = "claude-headless"
base_url = "https://example.test/anthropic"
api_key_env = "VERBOSE_TEST_KEY"
models = ["stub"]
[profiles]
p = ["test"]
EOF
  if [ -n "$1" ]; then
    { printf 'verbose_prompt = %s\n' "$1"; cat "$MULTI_HOME/config.toml"; } > "$TMP/config-next.toml"
    mv "$TMP/config-next.toml" "$MULTI_HOME/config.toml"
  fi
}
probe(){ bash "$TREE/scripts/probe.sh" 2>&1; }

echo "== only boolean true enables the probe signal =="
config ''
out="$(probe)"
say "absent key: no preview signal" "$(grep -c '^verbose-prompt:' <<<"$out")" "0"
config false
out="$(probe)"
say "false: no preview signal" "$(grep -c '^verbose-prompt:' <<<"$out")" "0"
config true
out="$(probe)"
say "true: one preview signal" "$(grep -cx 'verbose-prompt: on' <<<"$out")" "1"
cp "$MULTI_HOME/config.toml" "$TMP/verbose-on.toml"
config false
out="$(MULTI_CONFIG="$TMP/verbose-on.toml" probe)"
say "MULTI_CONFIG overrides false with true" "$(grep -cx 'verbose-prompt: on' <<<"$out")" "1"
config true
cp "$MULTI_HOME/config.toml" "$TMP/verbose-on-home.toml"
config false
cp "$MULTI_HOME/config.toml" "$TMP/verbose-off.toml"
cp "$TMP/verbose-on-home.toml" "$MULTI_HOME/config.toml"
out="$(MULTI_CONFIG="$TMP/verbose-off.toml" probe)"
say "MULTI_CONFIG overrides true with false" "$(grep -c '^verbose-prompt:' <<<"$out")" "0"
config '"true"'
out="$(probe)"
say "invalid key: config error" "$(grep -c '^config: BROKEN.*verbose_prompt must be a boolean' <<<"$out")" "1"
say "invalid key: no preview signal" "$(grep -c '^verbose-prompt:' <<<"$out")" "0"
config true
printf '\nunknown_key = true\n' >> "$MULTI_HOME/config.toml"
out="$(probe)"
say "invalid config: config error" "$(grep -c '^config: BROKEN' <<<"$out")" "1"
say "invalid config: no preview signal" "$(grep -c '^verbose-prompt:' <<<"$out")" "0"

echo "== Windows Store python3 stub falls back to working python =="
cat > "$TMP/bin/python3" <<'STUB'
#!/usr/bin/env bash
echo 'Python was not found; run without arguments to install from the Microsoft Store.'
exit 0
STUB
# A wrapper, not a symlink: macOS /usr/bin/python3 is an xcrun shim that
# dispatches on its argv[0], and has no tool named "python".
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$real_py" > "$TMP/bin/python"; chmod +x "$TMP/bin/python"
chmod +x "$TMP/bin/python3"
export PATH="$TMP/bin:$PATH"
config true
out="$(probe)"
say "working fallback: preview signal" "$(grep -cx 'verbose-prompt: on' <<<"$out")" "1"
say "Store stub stdout stays out of probe" "$(grep -c 'Python was not found' <<<"$out")" "0"
say "working fallback: valid config" "$(grep -c '^config: BROKEN' <<<"$out")" "0"
rm "$TMP/bin/python"
# A failure after `check` must still be a hard stop, not a quiet "off".
cat > "$TMP/bin/python" <<'STUB'
#!/usr/bin/env bash
if [ "${2:-}" = "verbose-prompt" ]; then
  echo 'config read failed' >&2
  exit 2
fi
exec "$TEST_REAL_PY" "$@"
STUB
chmod +x "$TMP/bin/python"
out="$(TEST_REAL_PY="$real_py" probe)"
say "preview read failed: config error" "$(grep -c '^config: BROKEN.*config read failed' <<<"$out")" "1"
say "preview read failed: no preview signal" "$(grep -c '^verbose-prompt:' <<<"$out")" "0"
say "preview read failed: no backend status" "$(grep -c '^test:' <<<"$out")" "0"
rm "$TMP/bin/python"
cp "$TMP/bin/python3" "$TMP/bin/python"
out="$(probe)"
say "no working interpreter: config error" "$(grep -c '^config: BROKEN.*no working python3' <<<"$out")" "1"
say "no working interpreter: no preview signal" "$(grep -c '^verbose-prompt:' <<<"$out")" "0"

echo "== the documented prompt files are complete before the send =="
mkdir -p "$TMP/scripts" "$TMP/prompt-run" "$TMP/prompt-copy"
cat > "$TMP/scripts/ask.sh" <<'STUB'
#!/usr/bin/env bash
question_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --question-file) question_file="$2"; shift 2 ;;
    --question) exit 2 ;;  # A preview and an inline argument can drift.
    *) shift ;;
  esac
done
[ -s "$question_file" ] || exit 2
cat "$question_file" > "$TEST_PROMPT_SENT"
STUB
chmod +x "$TMP/scripts/ask.sh"
export SCRIPTS="$TMP/scripts" TEST_PROMPT_RUN="$TMP/prompt-run" TEST_PROMPT_COPY="$TMP/prompt-copy"
export TEST_PROMPT_SENT="$TMP/sent.md"
for skill in ask check-if-done; do
  # Execute the skill's shell example with local paths and a capturing send.
  # Only illustrative CLI placeholders and target setup are substituted.
  "$real_py" - "$TREE/skills/$skill/SKILL.md" "$TMP/example.sh" "$TMP/expected.md" "$TMP/shell-ran" <<'PY'
import re
import sys
from pathlib import Path

skill_path, output, expected, marker = sys.argv[1:]
text = Path(skill_path).read_text()
block = re.search(r"```bash\n(.*?)\n```", text, re.S).group(1)
for name, fixture in (("RUN", "TEST_PROMPT_RUN"), ("REPO", "TEST_PROMPT_COPY"), ("COPY", "TEST_PROMPT_COPY")):
    block = re.sub(r"^" + name + r"=.*$", name + '="$' + fixture + '"', block, flags=re.M)
block = block.replace("[--diff <spec>]", "").replace("[--effort <low|medium|high|xhigh|max>]", "").replace("[--effort <user-named effort>]", "")
question = "A literal question: $(touch " + marker + ") and `touch " + marker + "`\n```````\nContext: keep this text as data."
block = block.replace("<the user's question, verbatim, plus any needed context>", question)
Path(expected).write_text(question + "\n")
Path(output).write_text(block + "\n")
PY
  bash "$TMP/example.sh"
  say "$skill: example send succeeds" "$?" "0"
  if [ "$skill" = ask ]; then
    say "ask: exact literal question and context reach the send" "$(cmp -s "$TMP/expected.md" "$TEST_PROMPT_SENT"; echo $?)" "0"
    say "ask: question shell syntax was not executed" "$([ -e "$TMP/shell-ran" ] && echo ran || echo no)" "no"
  else
    say "check-if-done: task instruction present at send time" "$(grep -c '^You are checking whether a task was actually finished' "$TEST_PROMPT_SENT")" "1"
    say "check-if-done: final instruction present at send time" "$(grep -c '^there, say so plainly\.$' "$TEST_PROMPT_SENT")" "1"
  fi
done

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
