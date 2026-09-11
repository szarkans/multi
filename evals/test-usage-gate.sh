#!/usr/bin/env bash
# Offline check of usage-gate.sh: the endpoint is replaced with a file:// fixture,
# so every answer shape can be played without the network. What matters most:
# an answer the gate cannot read must make it wait, never let a run through.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '{"claudeAiOauth":{"accessToken":"fixture"}}' > "$T/cred.json"
fail=0
# <name> <json> <want: go|wait>
case_() {
  printf '%s' "$2" > "$T/usage.json"; : > "$T/log"
  GATE_URL="file://$T/usage.json" GATE_CRED="$T/cred.json" GATE_QUIET=1 GATE_POLL=1 GATE_LOG="$T/log" \
    timeout 4 bash "$HERE/usage-gate.sh" > /dev/null 2>&1
  local rc=$? got=wait; [ "$rc" = 0 ] && got=go
  if [ "$got" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $got, want $3 ($(head -1 "$T/log"))"; fail=1; fi
}
W='"resets_at":"2026-09-11T16:50:00+00:00"'
case_ "room in both windows"        '{"five_hour":{"utilization":10,'"$W"'},"seven_day":{"utilization":5,'"$W"'}}' go
case_ "5-hour window over the line" '{"five_hour":{"utilization":80,'"$W"'},"seven_day":{"utilization":5,'"$W"'}}' wait
case_ "weekly window over the line" '{"five_hour":{"utilization":10,'"$W"'},"seven_day":{"utilization":75,'"$W"'}}' wait
case_ "5-hour window missing"       '{"seven_day":{"utilization":5,'"$W"'}}' wait
case_ "utilization null"            '{"five_hour":{"utilization":null,'"$W"'},"seven_day":{"utilization":5,'"$W"'}}' wait
case_ "utilization a string"        '{"five_hour":{"utilization":"10",'"$W"'},"seven_day":{"utilization":5,'"$W"'}}' wait
case_ "not json at all"             'maintenance' wait
case_ "Z-suffixed reset time"       '{"five_hour":{"utilization":10,"resets_at":"2026-09-11T16:50:00Z"},"seven_day":{"utilization":5,"resets_at":"2026-09-18T04:00:00Z"}}' go
case_ "unparseable reset time"      '{"five_hour":{"utilization":10,"resets_at":"soon"},"seven_day":{"utilization":5}}' go
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
