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

echo "== a non-secret setting still wants its value on the command line =="
bash "$TREE/scripts/setup.sh" set MULTI_OPENROUTER_MODEL </dev/null >/dev/null 2>&1
say "refused without a value" "$?" "2"
bash "$TREE/scripts/setup.sh" set MULTI_OPENROUTER_MODEL some/model >/dev/null 2>&1
say "accepted with one" "$(grep -c 'some/model' "$MULTI_HOME/providers.env")" "1"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
