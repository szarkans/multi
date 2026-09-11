#!/usr/bin/env bash
# Offline check of grade-arms.sh's cache and outage handling, with a stand-in
# `claude` that can answer a flatten or a vote with the usage-limit message.
# No model is called; the usage gate is a stand-in pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/ev"
cp "$HERE/grade-arms.sh" "$T/ev/"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/ev/usage-gate.sh"
LIMIT="You've hit your session limit · resets 4:50am (Europe/Moscow)"
cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
in="\$(cat)"
case "\$in" in
  *"Extract EVERY distinct finding"*) [ "\${STUB_FLAT:-ok}" = limit ] && { echo "$LIMIT"; exit 0; }; echo "a.py:1 | stub finding" ;;
  *) n=\$(( \$(cat "$T/votes" 2>/dev/null || echo 0) + 1 )); echo \$n > "$T/votes"
     [ "\$n" = "\${STUB_LIMIT_VOTE:-0}" ] && { echo "$LIMIT"; exit 0; }
     printf 'VERDICT: FOUND\nN_FINDINGS: 1\nQUOTE: a.py:1 | stub finding\n' ;;
esac
EOF
chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
fresh() { # a clean case dir with one real report
  rm -rf "$T/out" "$T/votes"; mkdir -p "$T/out"
  echo "the bug" > "$T/out/c1.truth.txt"; printf 'is_error=False\n' > "$T/out/c1.builtin.meta"
  printf 'report %s\n' "$(printf 'z%.0s' $(seq 900))" > "$T/out/c1.builtin.txt"
}
verdict() { sed -n 's/^VERDICT: *//p' "$T/out/c1.builtin.grade"; }

fresh; bash "$T/ev/grade-arms.sh" --out "$T/out" > /dev/null 2>&1
check "clean run grades" "$(verdict)" "FOUND"

fresh; STUB_FLAT=limit bash "$T/ev/grade-arms.sh" --out "$T/out" > /dev/null 2>&1
check "flatten answers with the limit: not a MISS" "$(verdict)" "UNGRADED"
check "flatten answers with the limit: nothing cached" "$([ -e "$T/out/c1.builtin.flat.txt" ] && echo kept || echo gone)" "gone"

fresh; STUB_LIMIT_VOTE=2 bash "$T/ev/grade-arms.sh" --out "$T/out" > /dev/null 2>&1
check "one vote starved: not a two-vote majority" "$(verdict)" "UNGRADED"
bash "$T/ev/grade-arms.sh" --out "$T/out" > /dev/null 2>&1
check "re-run fills the missing vote" "$(verdict)" "FOUND"

# The night's poison: a cached finding list that is the limit message, and three
# well-formed votes graded against it.
fresh; sleep 1
echo "$LIMIT" > "$T/out/c1.builtin.flat.txt"
for v in 1 2 3; do printf 'VERDICT: MISS\nN_FINDINGS: 0\nQUOTE: -\n' > "$T/out/c1.builtin.grade$v"; done
bash "$T/ev/grade-arms.sh" --out "$T/out" > /dev/null 2>&1
check "votes graded against a limit message are not reused" "$(verdict)" "FOUND"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
