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
# agy 1.4 keeps its sign-in outside HOME, so a missing token file is not a
# failure: the run still answers. Proven here by removing the file the old
# builds wrote and expecting a normal answer.
mv "$TMP/user/.gemini/antigravity-cli/antigravity-oauth-token" "$TMP/tok.bak"
bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r3" --backend agy --repo "$TMP/repo" >/dev/null 2>&1
say "no token file -> still runs" "$([ -e "$TMP/r3-agy.txt.dead" ] && echo dead || echo alive)" "alive"
say "  and no token link was made" "$([ -e "$TMP/user/.gemini/antigravity-cli/antigravity-oauth-token" ] && echo present || echo absent)" "absent"
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

echo "== the gate: globs, recursion and git blobs reach what the literal check cannot see =="
# These need real files, so the workspace is a real dir this time, not /r.
mkdir -p "$TMP/ws/sub" "$TMP/ws/pkg"
ln -sfn pkg "$TMP/ws/linkdir"
ln -sfn .env "$TMP/ws/leak"
ln -sfn ../.env "$TMP/ws/sub/leak2"
printf 'API_KEY=x\n' > "$TMP/ws/.env"
printf 'x\n' > "$TMP/ws/a.py" "$TMP/ws/sub/b.py"
printf 'K=v\n' > "$TMP/ws/pkg/.env"
# git add -f for the .env files: a host whose global excludesFile lists .env
# would silently skip them under `git add .`, leaving WS_BLOB empty and every
# blob/tracked-secret assertion failing for reasons unrelated to the code.
( cd "$TMP/ws" && git init -q . && git add . && git add -f .env pkg/.env && git -c user.email=t@t -c user.name=t commit -qm x ) >/dev/null 2>&1
WS_BLOB="$(git -C "$TMP/ws" rev-parse HEAD:.env)"; WS_COMMIT="$(git -C "$TMP/ws" rev-parse HEAD)"
wscmd(){ gate "$(python3 -c 'import json,sys; print(json.dumps({"workspacePaths":[sys.argv[1]],"toolCall":{"name":"run_command","args":{"CommandLine":sys.argv[2]}}}))' "$TMP/ws" "$1")"; }
say "cat .env* (suffix glob)" "$(wscmd 'cat .env*')" deny
say "cat .e* (prefix glob)" "$(wscmd 'cat .e*')" deny
say "cat /etc/* (glob escapes the roots)" "$(wscmd 'cat /etc/*')" deny
say "cat a.py* (glob, no secret match)" "$(wscmd 'cat a.py*')" allow
say "cat {x,.env} (brace alternation)" "$(wscmd 'cat {x,.env}')" deny
say "cat {.e,nv}nv (brace builds the name)" "$(wscmd 'cat {.e,nv}nv')" deny
say "cat {~,.}/.env (brace escapes the root)" "$(wscmd 'cat {~,.}/.env')" deny
say "cat .env{,} (trailing brace)" "$(wscmd 'cat .env{,}')" deny
say "cat .[^x]nv (bash ^ class)" "$(wscmd 'cat .[^x]nv')" deny
say "cat .en? (single-char glob)" "$(wscmd 'cat .en?')" deny
say "cat ?env (glob cannot match the dot)" "$(wscmd 'cat ?env')" allow
say "grep -rn KEY . (recursion reads .env)" "$(wscmd 'grep -rn KEY .')" deny
say "grep -rn KEY (no path = cwd)" "$(wscmd 'grep -rn KEY')" deny
say "grep -rn KEY * (globbed dirs recurse)" "$(wscmd 'grep -rn KEY *')" deny
say "grep --rec KEY . (unambiguous long prefix)" "$(wscmd 'grep --rec KEY .')" deny
say "grep --dereference-recursive KEY ." "$(wscmd 'grep --dereference-recursive KEY .')" deny
say "grep --directories recurse KEY . (separate value)" "$(wscmd 'grep --directories recurse KEY .')" deny
say "grep -d recurse KEY . (short form)" "$(wscmd 'grep -d recurse KEY .')" deny
say "grep -rn -A 3 KEY (a flag value is not a path — still cwd)" "$(wscmd 'grep -rn -A 3 KEY')" deny
say "grep -rn -m 5 KEY (same for -m)" "$(wscmd 'grep -rn -m 5 KEY')" deny
say "grep -r API_KEY linkdir (a symlinked target reads)" "$(wscmd 'grep -r API_KEY linkdir')" deny
say "grep -rn KEY sub (no secret in that tree)" "$(wscmd 'grep -rn KEY sub')" allow
say "grep -rn K pkg (secret in that tree)" "$(wscmd 'grep -rn K pkg')" deny
say "grep -r KEY a.py (file only)" "$(wscmd 'grep -r KEY a.py')" allow
say "grep -n '.*' a.py (regex operand, not a glob)" "$(wscmd "grep -n '.*' a.py")" allow
say "grep -r -eKEY sub (pattern via -e)" "$(wscmd 'grep -r -eKEY sub')" allow
say "git show HEAD:.env (blob arg)" "$(wscmd 'git show HEAD:.env')" deny
say "git show :.env (index blob)" "$(wscmd 'git show :.env')" deny
say "git show HEAD:a.py" "$(wscmd 'git show HEAD:a.py')" allow
say "git show <blob-sha of .env>" "$(wscmd "git show $WS_BLOB")" deny
say "git show <commit sha> — whole patch prints tracked .env" "$(wscmd "git show $WS_COMMIT")" deny
say "git log --format=%H:%s (colon, not a blob)" "$(wscmd 'git log --format=%H:%s')" allow
say "cat .e{n..a}v (descending brace range)" "$(wscmd 'cat .e{n..a}v')" deny
say "cat .e{a..z..1}v (brace range with step)" "$(wscmd 'cat .e{a..z..1}v')" deny
say "cat .e{z..a}v (descending range hits the name)" "$(wscmd 'cat .e{z..a}v')" deny
say "cat {a,{b,{c,{d,{e,{f,.env}}}}}} (over depth cap — deny, not truncate)" "$(wscmd 'cat {a,{b,{c,{d,{e,{f,.env}}}}}}')" deny
say "cat {,}{,}{,}{,}{,}{x,.env} (sequential groups — deny, not truncate)" "$(wscmd 'cat {,}{,}{,}{,}{,}{x,.env}')" deny
say "cat {0..300} (over alt cap — deny, not truncate)" "$(wscmd 'cat {0..300}')" deny
say "cat {x,a}.py (brace under cap)" "$(wscmd 'cat {x,a}.py')" allow
say "cat leak (file symlink to .env resolves)" "$(wscmd 'cat leak')" deny
say "cat sub/leak2 (nested file symlink to .env)" "$(wscmd 'cat sub/leak2')" deny
say "read_file a symlink that points at .env" "$(tool read_file "{\"Path\":\"$TMP/ws/leak\"}")" deny
say "grep -r KEY sub (file link not followed with -r)" "$(wscmd 'grep -r KEY sub')" allow
say "grep -R KEY sub (file link dereferenced with -R)" "$(wscmd 'grep -R KEY sub')" deny
say "grep -e '.env' a.py (-e value is a pattern, not a path)" "$(wscmd "grep -e '.env' a.py")" allow
say "grep --regexp=.env a.py (same, long option)" "$(wscmd 'grep --regexp=.env a.py')" allow
say "grep -n -e '.*' a.py (regex value, not a glob)" "$(wscmd "grep -n -e '.*' a.py")" allow
say "grep -f .env a.py (-f's file IS a path)" "$(wscmd 'grep -f .env a.py')" deny
say "git show <blob-sha abbreviated>" "$(wscmd "git show ${WS_BLOB:0:8}")" deny
say "git show <blob-sha uppercase>" "$(wscmd "git show $(printf %s "$WS_BLOB" | tr 'a-z' 'A-Z')")" deny
say "git show HEAD:.e* (REV pathspec wildcard)" "$(wscmd 'git show HEAD:.e*')" deny
say "git log -p -- '.e*' (pathspec wildcard hits tracked .env)" "$(wscmd "git log -p -- '.e*'")" deny
say "git log -p -- 'sub/*' (expands to a secret-symlink)" "$(wscmd "git log -p -- 'sub/*'")" deny
say "git ls-files -- 'a.*' (wildcards to no secret)" "$(wscmd "git ls-files -- 'a.*'")" allow
say "find . -name '.env*' (find pattern expands too)" "$(wscmd 'find . -name ".env*"')" deny
say "find . -name '*.py'" "$(wscmd 'find . -name "*.py"')" allow

# A dir symlink inside a walked tree points the read outside — and the
# third round caught content-emitting git reads printing a tracked secret
# without ever naming it, peel-suffix and brace paths to the same blob, and
# git grep reaching ignored files.
mkdir -p "$TMP/ws/deep"
ln -sfn /etc "$TMP/ws/deep/etc"
say "grep -R KEY deep (dir link inside walks out)" "$(wscmd 'grep -R KEY deep')" deny
say "grep -r KEY deep (-r does not follow the dir link)" "$(wscmd 'grep -r KEY deep')" allow
say "grep -e '-r' a.py (a pattern is not a flag)" "$(wscmd "grep -e '-r' a.py")" allow
say "grep -e '-R' a.py (same for -R)" "$(wscmd "grep -e '-R' a.py")" allow
say "grep -f.env a.py (attached -f value is a path)" "$(wscmd 'grep -f.env a.py')" deny
say "grep -f/etc/passwd a.py (attached -f, outside)" "$(wscmd 'grep -f/etc/passwd a.py')" deny
say "cat .e{a..z..0}v (bash coerces step 0 to 1)" "$(wscmd 'cat .e{a..z..0}v')" deny
say "git log -p (whole-tree patch prints tracked .env)" "$(wscmd 'git log -p')" deny
say "git diff (worktree patch, secret tracked)" "$(wscmd 'git diff')" deny
say "git diff HEAD~0..HEAD (revs — still the whole tree)" "$(wscmd 'git diff HEAD~0..HEAD')" deny
say "git log -p a.py (scoped to a clean path)" "$(wscmd 'git log -p a.py')" allow
say "git diff a.py (scoped operand, not a rev)" "$(wscmd 'git diff a.py')" allow
say "git log -p -- . (dot is everything)" "$(wscmd 'git log -p -- .')" deny
say "git show <blob>^{blob} (peel suffix)" "$(wscmd "git show ${WS_BLOB}^{blob}")" deny
say "git show {<blob>,x} (braces reach the blob)" "$(wscmd "git show {$WS_BLOB,x}")" deny
say "git log -p {.e*,x} (braces reach the pathspec)" "$(wscmd "git log -p {.e*,x}")" deny
say "git grep API_KEY (no pathspec — searches tracked .env)" "$(wscmd 'git grep API_KEY')" deny
say "git grep -e API_KEY (same via -e)" "$(wscmd 'git grep -e API_KEY')" deny
say "git grep API_KEY -- a.py (scoped clean)" "$(wscmd 'git grep API_KEY -- a.py')" allow
say "git grep --untracked x (reads ignored files)" "$(wscmd 'git grep --untracked x')" deny
say "git grep --no-exclude-standard x" "$(wscmd 'git grep --no-exclude-standard x')" deny
say "git grep --recurse-submodules x" "$(wscmd 'git grep --recurse-submodules x')" deny
say "git log -L1,2:.env (line history emits the file)" "$(wscmd 'git log -L1,2:.env')" deny
say "git show HEAD:sub/ (clean REV:path stays allow)" "$(wscmd 'git show HEAD:sub/')" allow
say "git log --stat (metadata, not content)" "$(wscmd 'git log --stat')" allow
say "git status (metadata, not content)" "$(wscmd 'git status')" allow

# And the other half of the contract: a repo that tracks no secret keeps
# every content-emitting git read open — the reviewer must read diffs.
mkdir -p "$TMP/ws2"
( cd "$TMP/ws2" && git init -q . && echo x > a.py && git add . && git -c user.email=t@t -c user.name=t commit -qm x ) >/dev/null 2>&1
ws2cmd(){ gate "$(python3 -c 'import json,sys; print(json.dumps({"workspacePaths":[sys.argv[1]],"toolCall":{"name":"run_command","args":{"CommandLine":sys.argv[2]}}}))' "$TMP/ws2" "$1")"; }
say "git log -p in a repo with NO tracked secret" "$(ws2cmd 'git log -p')" allow
say "git diff in a clean repo" "$(ws2cmd 'git diff')" allow
say "git show HEAD in a clean repo" "$(ws2cmd 'git show HEAD')" allow
say "git grep x in a clean repo" "$(ws2cmd 'git grep x')" allow

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
