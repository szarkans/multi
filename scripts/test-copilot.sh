#!/usr/bin/env bash
# Copilot integration uses a stub CLI: these tests spend no AI credits.
# Each block states the outcome it proves before it runs.
#
#   bash scripts/test-copilot.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/h" "$TMP/repo"
export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/h" STUB_ARGS="$TMP/args"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

cat > "$MULTI_HOME/config.toml" <<'CONFIG'
default_profile = "p"
[backends.copilot]
type = "copilot"
models = []
timeout = 17
[profiles]
p = ["copilot"]
CONFIG

cat > "$TMP/bin/copilot" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGS"
printf 'COPILOT_ALLOW_ALL=%s\n' "${COPILOT_ALLOW_ALL:-unset}" > "$STUB_ARGS.env"
printf 'GITHUB_COPILOT_PROMPT_MODE_WORKSPACE_MCP=%s\n' "${GITHUB_COPILOT_PROMPT_MODE_WORKSPACE_MCP:-unset}" >> "$STUB_ARGS.env"
printf 'GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=%s\n' "${GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS:-unset}" >> "$STUB_ARGS.env"
printf 'GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS=%s\n' "${GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS:-unset}" >> "$STUB_ARGS.env"
printf 'cwd=%s\n' "$PWD" >> "$STUB_ARGS.env"
model=auto
while [ "$#" -gt 0 ]; do
  case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac
done

case "${STUB_MODE:-ok}" in
  fail) printf '%s\n' '{"type":"assistant.message","data":{"phase":"final_answer","content":"UNTRUSTED PARTIAL ANSWER","model":"stub"}}' '{"type":"result","exitCode":0}'
        echo 'provider unavailable' >&2; exit 7 ;;
  empty) printf '%s\n' '{"type":"result","exitCode":0}'; exit 0 ;;
  partial) printf '%s\n' '{"type":"assistant.message","data":{"phase":"final_answer","content":"partial","model":"stub"}}'; exit 0 ;;
  failedresult) printf '%s\n' '{"type":"assistant.message","data":{"phase":"final_answer","content":"partial","model":"stub"}}' '{"type":"result","exitCode":1}'; exit 0 ;;
  badjson) echo '{broken'; exit 0 ;;
  no_phase) printf '%s\n' '{"type":"assistant.message","data":{"content":"unphased answer","model":"stub"}}' '{"type":"result","exitCode":0}'; exit 0 ;;
  no_model) printf '%s\n' '{"type":"assistant.message","data":{"phase":"final_answer","content":"model absent"}}' '{"type":"result","exitCode":0}'; exit 0 ;;
  tool_message) printf '%s\n' '{"type":"assistant.message","data":{"content":"not the answer","toolRequests":[{"name":"view"}]}}' '{"type":"result","exitCode":0}'; exit 0 ;;
esac
printf '%s\n' '{"type":"tool.execution_complete","data":{"output":"src/fake.py:1 | HIGH | read from a file"}}'
printf '%s\n' '{"type":"assistant.message","data":{"phase":"commentary","content":"tool progress is not answer"}}'
if [ "$model" = auto ]; then
  printf '%s\n' '{"type":"session.auto_mode_resolved","data":{"chosenModel":"stub-auto"}}'
  printf '%s\n' '{"type":"assistant.message","data":{"phase":"final_answer","content":"src/real.py:2 | LOW | final finding"}}'
else
  printf '{"type":"assistant.message","data":{"phase":"final_answer","content":"src/real.py:2 | LOW | final finding","model":"%s"}}\n' "$model"
fi
printf '%s\n' '{"type":"result","exitCode":0}'
STUB
cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_TIMEOUT:-0}" = 1 ] && exit 124
shift 3 # -k GRACE SECONDS; the remaining args start with copilot
"$@"
STUB
chmod +x "$TMP/bin/copilot" "$TMP/bin/timeout"

run(){ local name="$1"; shift; bash "$TREE/scripts/ask.sh" --question 'review this diff' --repo "$TMP/repo" --backend copilot --out-prefix "$TMP/$name" "$@" > "$TMP/$name.stdout" 2> "$TMP/$name.stderr"; }
arg(){ grep -Fxc -- "$1" "$STUB_ARGS" 2>/dev/null || true; }
dead(){ [ -s "$TMP/$1-copilot.txt.dead" ] && echo yes || echo no; }

# Success means an unpinned Student run selects Auto, omits reasoning effort,
# runs in --repo, and extracts only the completed final answer. Failure means
# routing or JSONL filtering is wrong, or an empty/partial event became a result.
echo "== Auto routing and final JSONL answer =="
COPILOT_ALLOW_ALL=true run auto; rc=$?
say "Auto run succeeds" "$rc" "0"
say "Auto model selected" "$(arg auto)" "1"
say "Auto does not set reasoning effort" "$(arg --reasoning-effort)" "0"
say "Auto resolves actual model" "$(grep -c 'Copilot (model: stub-auto)' "$TMP/auto-copilot.txt")" "1"
say "final answer retained" "$(grep -c 'src/real.py:2' "$TMP/auto-copilot.txt")" "1"
say "tool output excluded" "$(grep -c 'src/fake.py' "$TMP/auto-copilot.txt")" "0"
say "commentary excluded" "$(grep -c 'tool progress' "$TMP/auto-copilot.txt")" "0"
say "target directory used" "$(grep -Fxc "cwd=$TMP/repo" "$STUB_ARGS.env")" "1"

# Success means the CLI sees only read tools and cannot inherit broad trust,
# shell/write/MCP access, or repo instructions. Any missing guard is a failure.
echo "== permission boundary =="
for flag in '-p' '--available-tools=view,grep,glob' '--allow-tool=read' '--deny-tool=write' '--disable-builtin-mcps' '--disallow-temp-dir' '--no-custom-instructions' '--no-ask-user' '--no-auto-update' '--no-remote-export' '--output-format=json'; do
  say "flag $flag present" "$(arg "$flag")" "1"
done
say "allow-all flag absent" "$(arg --allow-all-tools)" "0"
say "yolo flag absent" "$(arg --yolo)" "0"
say "inherited allow-all cleared" "$(grep -Fxc 'COPILOT_ALLOW_ALL=false' "$STUB_ARGS.env")" "1"
for setting in GITHUB_COPILOT_PROMPT_MODE_WORKSPACE_MCP GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS; do
  say "$setting disabled" "$(grep -Fxc "$setting=false" "$STUB_ARGS.env")" "1"
done

# Success means a direct run in a repository with executable project Copilot
# hooks/settings refuses before the CLI starts. Failure would let startup hooks
# bypass the model's read-only tool list; review snapshots strip these files.
echo "== direct repo with project hooks is refused =="
for path in .github/hooks/evil.json .github/copilot/settings.json .github/mcp.json .mcp.json .claude/settings.json; do
  mkdir -p "$TMP/repo/$(dirname "$path")"
  printf '{}\n' > "$TMP/repo/$path"
  rm -f "$STUB_ARGS"
  run unsafe; rc=$?
  say "$path gives no live backend" "$rc" "1"
  say "$path marks the refusal" "$(grep -c 'UNSAFE REPO CONFIG' "$TMP/unsafe-copilot.txt.dead")" "1"
  say "$path never launches Copilot" "$([ -e "$STUB_ARGS" ] && echo launched || echo stopped)" "stopped"
  rm -f "$TMP/repo/$path"
  [ "$(dirname "$path")" = . ] || rmdir "$TMP/repo/$(dirname "$path")"
done

mkdir -p "$TMP/repo/nested" "$TMP/repo/.github"
printf '{"mcpServers":{}}\n' > "$TMP/repo/.github/mcp.json"
rm -f "$STUB_ARGS"
bash "$TREE/scripts/ask.sh" --question 'review this diff' --repo "$TMP/repo/nested" --backend copilot --out-prefix "$TMP/nested" > "$TMP/nested.stdout" 2> "$TMP/nested.stderr"; rc=$?
say "parent MCP config refuses nested repo" "$rc" "1"
say "parent MCP config never launches Copilot" "$([ -e "$STUB_ARGS" ] && echo launched || echo stopped)" "stopped"
rm -f "$TMP/repo/.github/mcp.json"

# A CLI version may omit phase or model from a valid completed message.
# Success means the answer survives while model identity remains honest.
echo "== optional JSONL fields =="
STUB_MODE=no_phase run no_phase; rc=$?
say "unphased final message accepted" "$rc" "0"
say "unphased content retained" "$(grep -c 'unphased answer' "$TMP/no_phase-copilot.txt")" "1"
STUB_MODE=no_model run no_model; rc=$?
say "answer without model accepted" "$rc" "0"
say "unknown model labeled" "$(grep -c 'Copilot (model: unknown)' "$TMP/no_model-copilot.txt")" "1"
STUB_MODE=tool_message run tool_message; rc=$?
say "unphased tool request is no answer" "$rc" "1"
say "unphased tool request marked dead" "$(dead tool_message)" "yes"

# Success means an explicit pin reaches --model unchanged and passes requested
# reasoning effort. A lost pin silently changes cost and reviewer identity.
echo "== explicit model pin =="
run pin_default --backend 'copilot:claude-sonnet-4.6'; rc=$?
say "pinned model runs at default effort" "$rc" "0"
say "default effort leaves CLI model settings alone" "$(arg --reasoning-effort)" "0"
run pin --backend 'copilot:claude-sonnet-4.6' --effort high; rc=$?
say "pinned run succeeds" "$rc" "0"
say "model pin reaches CLI" "$(arg claude-sonnet-4.6)" "1"
say "reasoning effort reaches CLI" "$(arg high)" "1"
say "answer names pinned model" "$(grep -c 'Copilot (model: claude-sonnet-4.6)' "$TMP/pin-copilot.txt")" "1"

# Success means a nonzero CLI exit cannot turn its stdout into an answer and
# keeps stderr in the dead log. Failure means the judge could trust a failed run.
echo "== provider failure =="
STUB_MODE=fail run fail; rc=$?
say "failed CLI gives no live backend" "$rc" "1"
say "failure marked dead" "$(dead fail)" "yes"
say "stderr retained" "$(grep -c 'provider unavailable' "$TMP/fail-copilot.txt.dead.log")" "1"
say "partial answer discarded" "$(grep -c 'UNTRUSTED PARTIAL ANSWER' "$TMP/fail-copilot.txt")" "0"

# Success means timeout 124 becomes a dead backend with the configured 17s
# limit in its reason. Failure means a hung backend may look like a response.
echo "== timeout =="
STUB_TIMEOUT=1 run timeout; rc=$?
say "timeout gives no live backend" "$rc" "1"
say "timeout marked dead" "$(dead timeout)" "yes"
say "configured deadline reported" "$(grep -c 'TIMEOUT after 17s' "$TMP/timeout-copilot.txt.dead")" "1"

# Success means result-without-answer, answer-without-result, failed result,
# and malformed JSONL all fail closed. Failure means progress or corrupt output
# is trusted.
echo "== incomplete and invalid JSONL =="
for mode in empty partial failedresult badjson; do
  STUB_MODE="$mode" run "$mode"; rc=$?
  say "$mode has no live backend" "$rc" "1"
  say "$mode marked dead" "$(dead "$mode")" "yes"
done

[ "$fail" -eq 0 ] && echo 'ALL PASS' || echo 'FAILURES'
exit "$fail"
