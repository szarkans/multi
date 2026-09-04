#!/usr/bin/env bash
# A key must be settable without ever appearing on a command line. `setup.sh
# set NAME` with no value reads it from stdin -- typed without echo, or piped
# -- because a key in argv is in the shell history, visible in `ps`, and, when
# the setup skill runs the command, in the session transcript. chmod 600 on
# the file afterwards undoes none of that.
#
#   bash scripts/test-key-entry.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MULTI_HOME="$TMP/home"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

echo "== piped key is stored, and never printed in full =="
out=$(printf '%s' 'sk-or-v1-SECRETVALUE12345' | bash "$TREE/scripts/setup.sh" set OPENROUTER_API_KEY 2>&1)
say "stored" "$(grep -c "SECRETVALUE" "$MULTI_HOME/providers.env" 2>/dev/null)" "1"
say "not echoed in full" "$(printf '%s' "$out" | grep -c 'SECRETVALUE12345')" "0"
# chmod is a no-op on MSYS and on some mounts. Either the file really is
# owner-only, or setup.sh has to have said out loud that it is not -- what is
# not allowed is the silent middle, where the skill promises 600 and the file
# is readable by anyone.
perms="$(ls -l "$MULTI_HOME/providers.env" | cut -c1-10)"
case "$perms" in
  -rw-------) say "owner-only file" "ok" "ok" ;;
  *) say "not owner-only, and said so ($perms)" "$(printf '%s' "$out" | grep -ci 'not owner-only')" "1" ;;
esac

echo "== the old argv form still works, with a warning =="
out=$(bash "$TREE/scripts/setup.sh" set GEMINI_API_KEY AIzaOLDSTYLE 2>&1)
say "still stored" "$(grep -c 'AIzaOLDSTYLE' "$MULTI_HOME/providers.env")" "1"
say "warns about history" "$(printf '%s' "$out" | grep -ci 'shell history')" "1"

echo "== empty stdin is refused, not stored as an empty key =="
printf '' | bash "$TREE/scripts/setup.sh" set OPENROUTER_API_KEY >/dev/null 2>&1
say "refused" "$?" "2"
say "old value intact" "$(grep -c 'SECRETVALUE' "$MULTI_HOME/providers.env")" "1"

echo "== a key piped from a CRLF file is stored without the CR =="
printf 'sk-crlf-key\r\n' | bash "$TREE/scripts/setup.sh" set OPENROUTER_API_KEY >/dev/null 2>&1
# Compare the whole line: grep for a bare CR behaves differently across
# platforms, and what matters is the exact bytes that were stored.
say "stored exactly, no trailing CR" \
  "$(grep -c "^export OPENROUTER_API_KEY='sk-crlf-key'$" "$MULTI_HOME/providers.env")" "1"

echo "== only names some backend reads a key from are accepted =="
bash "$TREE/scripts/setup.sh" set MULTI_OPENROUTER_MODEL some/model >"$TMP/out" 2>&1
say "an old MULTI_* knob is refused" "$?" "2"
say "and pointed at config.toml" "$(grep -c 'config.toml' "$TMP/out")" "1"
printf 'k' | bash "$TREE/scripts/setup.sh" set TOTALLY_UNKNOWN_KEY >"$TMP/out" 2>&1
say "an unknown name is refused" "$?" "2"
say "nothing unknown was stored" "$(grep -c 'TOTALLY_UNKNOWN\|some/model' "$MULTI_HOME/providers.env")" "0"

echo "== a custom api_key_env in config.toml becomes an accepted name =="
mkdir -p "$MULTI_HOME"
cat > "$MULTI_HOME/config.toml" <<'EOF'
default_profile = "p"
[backends.zcode]
type = "claude-headless"
base_url = "https://example.test/api"
api_key_env = "ZAI_KEY"
models = ["m"]
[profiles]
p = ["zcode"]
EOF
printf 'zai-secret' | bash "$TREE/scripts/setup.sh" set ZAI_KEY >/dev/null 2>&1
say "custom key name accepted" "$?" "0"
say "stored" "$(grep -c "^export ZAI_KEY='zai-secret'$" "$MULTI_HOME/providers.env")" "1"
printf 'k' | bash "$TREE/scripts/setup.sh" set OPENROUTER_API_KEY >/dev/null 2>&1
say "a name no backend in THIS config reads is refused" "$?" "2"
mv "$MULTI_HOME/config.toml" "$MULTI_HOME/config.toml.keep"   # built-in default: codex and opencode read no key
printf 'k' | bash "$TREE/scripts/setup.sh" set CODEX_API_KEY >/dev/null 2>&1
say "a key for a type that reads none is refused" "$?" "2"
mv "$MULTI_HOME/config.toml.keep" "$MULTI_HOME/config.toml"

echo "== pre-config knobs left in providers.env stop every run =="
# The key was set for a custom endpoint; a config that ignored the old
# MULTI_OPENROUTER_BASE_URL line would send it to openrouter.ai instead.
printf "export MULTI_OPENROUTER_BASE_URL='https://api.example.test'\n" >> "$MULTI_HOME/providers.env"
bash "$TREE/scripts/ask.sh" --question q --backend zcode --out-prefix "$TMP/stale" >/dev/null 2>"$TMP/err"
say "ask.sh refuses to run" "$?" "2"
say "and names the variable and the file to move it to" "$(grep -c 'MULTI_OPENROUTER_BASE_URL.*config.toml' "$TMP/err")" "1"
say "nothing was launched" "$([ -e "$TMP/stale-zcode.txt" ] && echo launched || echo no)" "no"
bash "$TREE/scripts/setup.sh" status >/dev/null 2>&1; say "setup.sh status says so too" "$?" "2"
# init is the way out of that state, so it is exempt from the stop.
mv "$MULTI_HOME/config.toml" "$MULTI_HOME/config.toml.keep"
bash "$TREE/scripts/setup.sh" init >/dev/null 2>&1; say "but init, the way out, still works" "$?" "0"
say "and wrote the template" "$([ -s "$MULTI_HOME/config.toml" ] && echo yes || echo no)" "yes"
mv "$MULTI_HOME/config.toml.keep" "$MULTI_HOME/config.toml"
sed -i.bak 's/^export MULTI_OPENROUTER_BASE_URL/# &/' "$MULTI_HOME/providers.env"
# The old file was `.`-sourced, so a bare assignment counted too; the stop must see it.
printf "MULTI_OPENROUTER_MODELS='a b'\n" >> "$MULTI_HOME/providers.env"
bash "$TREE/scripts/ask.sh" --question q --backend zcode --out-prefix "$TMP/stale3" >/dev/null 2>"$TMP/err"
say "a bare assignment without export is caught too" "$(grep -c 'MULTI_OPENROUTER_MODELS' "$TMP/err")" "1"
sed -i.bak '/^MULTI_OPENROUTER_MODELS=/d' "$MULTI_HOME/providers.env"
bash "$TREE/scripts/ask.sh" --question q --backend zcode --out-prefix "$TMP/stale2" >/dev/null 2>&1
say "a commented-out line is fine" "$([ -e "$TMP/stale2-zcode.txt" ] && echo ran || echo no)" "ran"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
