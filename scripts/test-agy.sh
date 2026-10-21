#!/usr/bin/env bash
# The agy backend: Google Antigravity CLI. A stub `agy` on PATH, no network, no
# real CLI. agy is NOT read-only on its own: read-only comes from the isolated
# HOME multi builds (settings + a PreToolUse hook running scripts/agy-gate.py),
# so this test reads both back from inside the stub, then unit-tests the gate.
#
#   bash scripts/test-agy.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/h" "$TMP/user/.gemini/antigravity-cli" "$TMP/user/.gemini/config"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# multi runs agy with the isolated HOME as $HOME; the stub records what agy
# actually sees and copies the files multi prepared into it.
# multi runs agy under env -i, so the stub cannot get its output dir from the
# environment: it is written into the stub here.
sed "s#@DIR@#$TMP#" > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
AGY_TEST_DIR=@DIR@
env | cut -d= -f1 | sort > "$AGY_TEST_DIR/env"
printf '%s\n' "$@" > "$AGY_TEST_DIR/argv"
printf '%s' "$HOME" > "$AGY_TEST_DIR/home"
cp "$HOME/.gemini/config/hooks.json" "$AGY_TEST_DIR/hooks.json" 2>/dev/null
cp "$HOME/.gemini/antigravity-cli/settings.json" "$AGY_TEST_DIR/settings.json" 2>/dev/null
[ -L "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ] && readlink "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" > "$AGY_TEST_DIR/token-link"
ls "$HOME/.gemini/config" > "$AGY_TEST_DIR/config-ls"
echo "a.py:1 | HIGH | agy finding"
STUB
chmod +x "$TMP/bin/agy"
printf 'tok\n' > "$TMP/user/.gemini/antigravity-cli/antigravity-oauth-token"
printf 'user hook\n' > "$TMP/user/.gemini/config/user-skill.md"
export SECRET_API_KEY=leak MULTI_HOME="$TMP/h" PATH="$TMP/bin:$PATH" HOME="$TMP/user"
printf 'default_profile = "p"\n[backends.agy]\ntype = "agy"\nmodels = ["claude-sonnet-4-6"]\n[profiles]\np = ["agy"]\n' > "$TMP/acfg.toml"
export MULTI_CONFIG="$TMP/acfg.toml"
mkdir -p "$TMP/repo"; ( cd "$TMP/repo" && git init -q . && echo x > a.py && git add . ) >/dev/null 2>&1

echo "== an agy run: answer lands, read-only comes from the isolated HOME =="
bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r1" --backend agy --repo "$TMP/repo" >/dev/null 2>&1
say "answer written" "$(grep -c 'agy finding' "$TMP/r1-agy.txt" 2>/dev/null)" "1"
say "no dead marker" "$([ -e "$TMP/r1-agy.txt.dead" ] && echo dead || echo alive)" "alive"
say "argv is -p <q> --model claude-sonnet-4-6" "$(tr '\n' ' ' < "$TMP/argv")" "-p q --model claude-sonnet-4-6 "
for f in --mode --disable-slash-commands --dangerously-skip-permissions --effort; do
  say "never $f" "$(grep -c -x -- "$f" "$TMP/argv")" "0"
done
case "$(cat "$TMP/home")" in "$TMP/h/agy-home/run."*) r=ok ;; *) r="$(cat "$TMP/home")" ;; esac
say "HOME seen by agy is a per-run dir under agy-home" "$r" ok
say "  and it is removed after the run" "$([ -e "$(cat "$TMP/home")" ] && echo kept || echo gone)" gone
say "agy env carries no key from providers.env" "$(grep -c '_API_KEY' "$TMP/env")" 0
say "  and not the user's HOME" "$([ "$(cat "$TMP/home")" != "$TMP/user" ] && echo y || echo n)" "y"
say "hooks.json runs scripts/agy-gate.py" "$(python3 -c '
import json,sys
h=json.load(open(sys.argv[1]))["multi-readonly"]["PreToolUse"][0]
print(h["matcher"], h["hooks"][0]["command"])' "$TMP/hooks.json")" "* python3 -I $TREE/scripts/agy-gate.py"
say "settings: toolPermission proceed-in-sandbox" "$(python3 -c '
import json,sys; s=json.load(open(sys.argv[1])); print(s["toolPermission"], s["enableTerminalSandbox"])' "$TMP/settings.json")" "proceed-in-sandbox True"
say "token is a symlink to the user's token" "$(cat "$TMP/token-link")" "$TMP/user/.gemini/antigravity-cli/antigravity-oauth-token"
say "user's ~/.gemini/config is not visible" "$(cat "$TMP/config-ls")" "hooks.json"
say "training recorded as yes" "$(cat "$TMP/r1-agy.txt.trains")" "yes claude-sonnet-4-6"

echo "== a second run rebuilds the home (idempotent) =="
bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r1b" --backend agy --repo "$TMP/repo" >/dev/null 2>&1
say "second run answers too" "$([ -e "$TMP/r1b-agy.txt.dead" ] && echo dead || echo alive)" "alive"

echo "== --read-dir reaches agy as --add-dir =="
bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r2" --backend agy --repo "$TMP/repo" --read-dir "$TMP/repo" >/dev/null 2>&1
say "--add-dir <dir> in argv" "$(grep -A1 -x -- --add-dir "$TMP/argv" | tail -1)" "$(cd "$TMP/repo" && pwd -P)"

echo "== failures =="
mv "$TMP/user/.gemini/antigravity-cli/antigravity-oauth-token" "$TMP/tok.bak"
bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r3" --backend agy --repo "$TMP/repo" >/dev/null 2>&1
say "no token -> dead" "$([ -e "$TMP/r3-agy.txt.dead" ] && echo dead || echo alive)" "dead"
say "  says NOT LOGGED IN" "$(grep -c 'NOT LOGGED IN' "$TMP/r3-agy.txt")" "1"
mv "$TMP/tok.bak" "$TMP/user/.gemini/antigravity-cli/antigravity-oauth-token"
( PATH="/usr/bin:/bin"; bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r4" --backend agy --repo "$TMP/repo" >/dev/null 2>&1 )
say "no agy binary -> dead" "$([ -e "$TMP/r4-agy.txt.dead" ] && echo dead || echo alive)" "dead"
say "  says MISSING" "$(grep -c 'agy: MISSING' "$TMP/r4-agy.txt")" "1"

echo "== config rules =="
printf 'default_profile = "p"\n[backends.agy]\ntype = "agy"\nmodels = ["a","b"]\n[profiles]\np = ["agy"]\n' > "$TMP/two.toml"
say "two models for agy -> config error" "$(MULTI_CONFIG="$TMP/two.toml" python3 "$TREE/scripts/config.py" check >/dev/null 2>&1; echo $?)" "2"
printf 'default_profile = "p"\n[backends.agy]\ntype = "agy"\nmodels = ["a"]\neffort = { "a" = "high" }\n[profiles]\np = ["agy"]\n' > "$TMP/eff.toml"
say "effort for agy -> config error" "$(MULTI_CONFIG="$TMP/eff.toml" python3 "$TREE/scripts/config.py" check >/dev/null 2>&1; echo $?)" "2"
say "no agy backend in the built-in config" "$(MULTI_CONFIG=/nonexistent python3 "$TREE/scripts/config.py" backends 2>/dev/null | cut -f2 | grep -c '^agy$')" "0"

echo "== the gate: deny by default =="
gate(){ printf '%s' "$1" | python3 -I "$TREE/scripts/agy-gate.py" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"])'; }
tool(){ gate "$(python3 -c 'import json,sys; print(json.dumps({"workspacePaths":["/r","/skill"],"toolCall":{"name":sys.argv[1],"args":json.loads(sys.argv[2])}}))' "$1" "$2")"; }
cmd(){ tool run_command "$(python3 -c 'import json,sys; print(json.dumps({"CommandLine":sys.argv[1]}))' "$1")"; }
say "read_file a.py" "$(tool read_file '{"AbsolutePath":"/r/a.py"}')" allow
say "read_file .env" "$(tool read_file '{"AbsolutePath":"/r/.env"}')" deny
say "read_file .env.example" "$(tool read_file '{"AbsolutePath":"/r/.env.example"}')" allow
say "read_file in the --add-dir root" "$(tool read_file '{"Path":"/skill/SKILL.md"}')" allow
say "read_file outside the workspace" "$(tool read_file '{"Path":"/etc/passwd"}')" deny
say "read_file sibling with a shared prefix" "$(tool read_file '{"Path":"/rx/a.py"}')" deny
say "read_file escaping with .." "$(tool read_file '{"Path":"/r/../etc/passwd"}')" deny
say "read_file with no workspace in the payload" "$(gate '{"toolCall":{"name":"read_file","args":{"Path":"/r/a.py"}}}')" deny
say "write_file" "$(tool write_file '{"AbsolutePath":"/r/a.py"}')" deny
say "edit_file" "$(tool edit_file '{"AbsolutePath":"/r/a.py"}')" deny
say "invoke_subagent" "$(tool invoke_subagent '{}')" deny
say "grep -rn div ." "$(cmd 'grep -rn div .')" allow
say "git diff" "$(cmd 'git diff')" allow
say "find . -type f" "$(cmd 'find . -type f')" allow
say "find . -delete" "$(cmd 'find . -delete')" deny
say "ls | head" "$(cmd 'ls | head')" deny
say "cd /x && ls" "$(cmd 'cd /x && ls')" deny
say "rm -rf x" "$(cmd 'rm -rf x')" deny
say "rg --pre sh x" "$(cmd 'rg --pre sh x')" deny
say "git grep -Ovim x" "$(cmd 'git grep -Ovim x')" deny
say "git -c core.pager=sh log" "$(cmd 'git -c core.pager=sh log')" deny
say 'cat $(id)' "$(cmd 'cat $(id)')" deny
say "garbage stdin" "$(gate 'not json{')" deny
# Found by the multi review of this change: each one was an allow or a crash before.
say "toolCall is a string" "$(gate '{"workspacePaths":["/r"],"toolCall":"x"}')" deny
say "args is a string" "$(gate '{"workspacePaths":["/r"],"toolCall":{"name":"run_command","args":"ls"}}')" deny
say "read_file ../../etc/hosts" "$(tool read_file '{"Path":"../../etc/hosts"}')" deny
say "read_file under a renamed key" "$(tool read_file '{"TargetFile":"/etc/passwd"}')" deny
say "read_file .ENV (case)" "$(tool read_file '{"Path":"/r/.ENV"}')" deny
say "cat /proc/self/environ" "$(cmd 'cat /proc/self/environ')" deny
say "grep -r KEY /" "$(cmd 'grep -r KEY /')" deny
say "cat ../x" "$(cmd 'cat ../x')" deny
say "cat ~/.ssh/id_rsa" "$(cmd 'cat ~/.ssh/id_rsa')" deny
say "grep pattern that only looks like a path" "$(cmd 'grep -rn /api/v1/nowhere .')" allow
say "git grep -nOsh x (clustered -O)" "$(cmd 'git grep -nOsh x')" deny
say "git grep --open-f=sh x (abbreviated)" "$(cmd 'git grep --open-f=sh x')" deny
say "git diff --ext (abbreviated)" "$(cmd 'git diff --ext')" deny
say "git log --name-only" "$(cmd 'git log --name-only')" allow
say "rg is not allowed" "$(cmd 'rg x')" deny
say "file -C is not allowed" "$(cmd 'file -C')" deny
say "tail -f" "$(cmd 'tail -f a.py')" deny
say "tail -n 5" "$(cmd 'tail -n 5 a.py')" allow

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
