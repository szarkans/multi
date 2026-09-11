#!/usr/bin/env bash
# Offline check of run-arms.sh's decision what counts as a result: a stand-in
# `claude` plays each shape seen on the night of 2026-09-11 (and the ones the
# review of that fix asked about) on its first call, then succeeds. No model is
# called, and the usage gate is a stand-in too -- test-usage-gate.sh covers it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/wt" "$T/out"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo $n > "$STUB_DIR/calls"
res() { printf '{"type":"result","subtype":"success","is_error":%s,"result":"%s","total_cost_usd":%s,"num_turns":5,"duration_ms":900,"usage":{}}\n' "$1" "$2" "$3"; }
long="REPORT $(printf 'x%.0s' $(seq 900))"
if [ "$n" -gt 1 ]; then res false "$long" 1.5; exit 0; fi
case "$STUB_SHAPE" in
  ok)          res false "$long" 1.5 ;;
  overage)     echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","overageStatus":"allowed","isUsingOverage":true}}'
               res false "$long" 1.5 ;;             # rejected on the window, finished on paid overage
  limit)       res true "You've hit your session limit · resets 4:50am (Europe/Moscow)" 0 ;;
  stub403)     res true "Failed to authenticate. API Error: 403 Request not allowed" 0 ;;
  empty)       res false "" 0 ;;
  midwall)     res true "You've hit your session limit · resets 4:50am (Europe/Moscow)" 2.5 ;;   # worked, then the wall
  legit_short) res false 'Checked the diff.\nAPI Error: 403 is raised on purpose at L12, fine.\nNo defects.' 0.5 ;;
  errored)     res true "ERRTEXT $(printf 'y%.0s' $(seq 900))" 1.2 ;;
  killed_timeout) exit 124 ;;                       # no result event, the timeout's exit code
  killed_crash)   exit 1 ;;
esac
EOF
chmod +x "$T/bin/claude"

OUT="$T/out"; TIMEOUT=60; MODEL=sonnet
eval "$(sed -n '/^run_arm() {/,/^while IFS/p' "$HERE/run-arms.sh" | sed '$d')"
HERE="$T"; export PATH="$T/bin:$PATH" STUB_DIR="$T"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# <shape> <calls after first arm> <attempt set aside> <calls after a re-run>
for row in "ok 1 no 1" "overage 1 no 1" "limit 2 yes 2" "stub403 2 yes 2" "empty 2 yes 2" \
           "midwall 2 yes 2" "legit_short 1 no 1" "errored 1 no 2" "killed_timeout 1 no 1" "killed_crash 1 no 2"; do
  set -- $row
  rm -rf "$OUT"; mkdir -p "$OUT"; rm -f "$T/calls"; INCOMPLETE=""
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/usage-gate.sh"
  export STUB_SHAPE=$1
  arm c1 builtin "$T/wt" "/code-review high HEAD~1..HEAD" > /dev/null
  check "$1: calls" "$(cat "$T/calls")" "$2"
  aside=no; ls "$OUT"/c1.builtin.*.limit-* > /dev/null 2>&1 && aside=yes
  check "$1: failed attempt set aside" "$aside" "$3"
  arm c1 builtin "$T/wt" "/code-review high HEAD~1..HEAD" > /dev/null
  check "$1: calls after a re-run" "$(cat "$T/calls")" "$4"
done

# A gate that exits non-zero was killed, not cleared: nothing may run.
rm -rf "$OUT"; mkdir -p "$OUT"; rm -f "$T/calls"; INCOMPLETE=""
printf '#!/usr/bin/env bash\nexit 143\n' > "$T/usage-gate.sh"
arm c1 builtin "$T/wt" "/code-review high HEAD~1..HEAD" > /dev/null
check "killed gate: nothing ran" "$(cat "$T/calls" 2>/dev/null || echo 0)" "0"
check "killed gate: arm reported incomplete" "$INCOMPLETE" " c1.builtin"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
