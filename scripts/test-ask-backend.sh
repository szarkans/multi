#!/usr/bin/env bash
# Checks --backend routing in ask.sh: the flag must actually skip a backend,
# not just relabel the output. Uses stub codex/opencode on PATH, so it needs
# no network, no API keys and no real CLI installed.
#
#   bash scripts/test-ask-backend.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out="$2"; shift; }; shift; done
[ -n "$out" ] && echo "CODEX ANSWER" > "$out"
STUB
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "OPENCODE ANSWER"
STUB
chmod +x "$TMP/bin/codex" "$TMP/bin/opencode"
export PATH="$TMP/bin:$PATH"

fail=0
check() { # name expect_codex expect_opencode
  local n="$1" ec="$2" eo="$3" p="$TMP/$1"
  local gc=no go=no
  [ -f "$p-codex.txt" ] && gc=yes
  [ -f "$p-opencode.txt" ] && go=yes
  if [ "$gc" = "$ec" ] && [ "$go" = "$eo" ]; then
    echo "ok   $n (codex=$gc opencode=$go)"
  else
    echo "FAIL $n: expected codex=$ec opencode=$eo, got codex=$gc opencode=$go"; fail=1
  fi
}

"$HERE/ask.sh" --question q --out-prefix "$TMP/both"  --model m >/dev/null
check both yes yes
"$HERE/ask.sh" --question q --out-prefix "$TMP/only-cx" --model m --backend codex >/dev/null
check only-cx yes no
"$HERE/ask.sh" --question q --out-prefix "$TMP/only-oc" --model m --backend opencode >/dev/null
check only-oc no yes

# A typo in the backend name must stop the run, not silently fall through to both.
"$HERE/ask.sh" --question q --out-prefix "$TMP/bogus" --model m --backend gpt >/dev/null 2>&1
[ $? -eq 2 ] && echo "ok   bad backend rejected" || { echo "FAIL bad backend not rejected"; fail=1; }

# Both files must carry the answer, not an empty file that reads as one.
grep -q "CODEX ANSWER" "$TMP/both-codex.txt" || { echo "FAIL codex answer not written"; fail=1; }
grep -q "OPENCODE ANSWER" "$TMP/both-opencode.txt" || { echo "FAIL opencode answer not written"; fail=1; }

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
