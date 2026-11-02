#!/usr/bin/env bash
# `host:` must name the harness that is actually running. Every marker is
# cleared first, or the developer's own session would answer for the test:
# an omp session carries OMPCODE=1 and CLAUDECODE=1 at once.
#
#   bash scripts/test-host-detect.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

CLEAR="env -u OMPCODE -u OPENCODE -u CLAUDECODE -u CODEX_HOME -u CODEX_SANDBOX"
# Run host_detect in a clean environment; extra args are env assignments.
detect() {
  $CLEAR "$@" bash -c '. "$1/scripts/host-detect.sh"; host_detect' _ "$TREE"
}

echo "== env markers, one at a time =="
say "OMPCODE=1" "$(detect OMPCODE=1)" "omp"
say "OMPCODE wins over CLAUDECODE" "$(detect OMPCODE=1 CLAUDECODE=1)" "omp"
say "OPENCODE=1" "$(detect OPENCODE=1)" "opencode"
say "CLAUDECODE=1" "$(detect CLAUDECODE=1)" "claude-code"
say "CODEX_HOME set" "$(detect CODEX_HOME=/tmp/x)" "codex"
say "CODEX_SANDBOX set" "$(detect CODEX_SANDBOX=/tmp/x)" "codex"
say "CODEX_HOME does not outvote CLAUDECODE" "$(detect CODEX_HOME=/tmp/x CLAUDECODE=1)" "claude-code"

echo "== no markers: the parent process decides =="
# A copied shell under a neutral name, because this very test may run inside a
# harness: the marker-free case must not borrow the developer's own session.
BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT
cp "$(command -v bash)" "$BIN/zz-neutral"
cp "$(command -v bash)" "$BIN/zz-codex-zz"
say "unknown when the parent matches nothing" \
  "$($CLEAR "$BIN/zz-neutral" -c '. "$1/scripts/host-detect.sh"; host_detect' _ "$TREE")" "unknown"
say "parent name alone is enough" \
  "$($CLEAR "$BIN/zz-codex-zz" -c 'bash -c ". \"\$1/scripts/host-detect.sh\"; host_detect" _ "$1"; echo -n' _ "$TREE")" "codex"

echo "== the probe prints the line =="
home="$(mktemp -d)"; trap 'rm -rf "$BIN" "$home"' EXIT
say "probe prints host: omp under OMPCODE=1" \
  "$($CLEAR OMPCODE=1 MULTI_HOME="$home" "$TREE/scripts/probe.sh" 2>/dev/null | grep -c '^host: omp$')" "1"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
