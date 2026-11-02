#!/usr/bin/env bash
# `host:` must name the harness that is actually running. Every marker is
# cleared first, or the developer's own session would answer for the test:
# an omp session carries OMPCODE=1 and CLAUDECODE=1 at once.
#
# The two sources are tested apart, because a test running inside a harness can
# never reach the marker branch through host_detect: its own ancestors answer
# first, by design.
#
#   bash scripts/test-host-detect.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

CLEAR="env -u OMPCODE -u OPENCODE -u OPENCODE_PID -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_THREAD_ID -u CODEX_HOME -u CODEX_SANDBOX"
# Run one function from host-detect.sh in a clean environment; extra args are
# env assignments.
run() {
  fn="$1"; shift
  $CLEAR "$@" bash -c '. "$1/scripts/host-detect.sh"; "$2" || echo unknown' _ "$TREE" "$fn"
}

BIN="$(mktemp -d)"
home="$(mktemp -d)"
trap 'rm -rf "$BIN" "$home"' EXIT
cat > "$BIN/inner.sh" <<'EOS'
#!/usr/bin/env bash
. "$1/scripts/host-detect.sh"
host_detect
EOS
chmod +x "$BIN/inner.sh"
cp "$(command -v bash)" "$BIN/zz-neutral"
cp "$(command -v bash)" "$BIN/zz-codex-zz"
cp "$(command -v bash)" "$BIN/zz-opencode-zz"

echo "== markers, most specific first =="
say "OPENCODE_PID" "$(run host_from_markers OPENCODE_PID=4242)" "opencode"
say "CODEX_THREAD_ID" "$(run host_from_markers CODEX_THREAD_ID=cdx-1)" "codex"
say "OMPCODE" "$(run host_from_markers OMPCODE=1)" "omp"
say "CLAUDE_CODE_ENTRYPOINT" "$(run host_from_markers CLAUDE_CODE_ENTRYPOINT=cli)" "claude-code"
say "CLAUDECODE" "$(run host_from_markers CLAUDECODE=1)" "claude-code"
say "CODEX_SANDBOX" "$(run host_from_markers CODEX_SANDBOX=/tmp/x)" "codex"
say "CODEX_HOME" "$(run host_from_markers CODEX_HOME=/tmp/x)" "codex"

echo "== the inner harness wins when both answer =="
say "OMPCODE beats CLAUDECODE" "$(run host_from_markers OMPCODE=1 CLAUDECODE=1)" "omp"
say "a codex thread beats the omp session it was started from" "$(run host_from_markers OMPCODE=1 CLAUDECODE=1 CODEX_THREAD_ID=cdx-1)" "codex"
say "an opencode pid beats the omp session it was started from" "$(run host_from_markers OMPCODE=1 OPENCODE_PID=4242)" "opencode"
say "CODEX_HOME does not outvote CLAUDECODE" "$(run host_from_markers CODEX_HOME=/tmp/x CLAUDECODE=1)" "claude-code"
say "a shell-exported CODEX_HOME does not outvote OMPCODE" "$(run host_from_markers CODEX_HOME=/tmp/x OMPCODE=1)" "omp"

echo "== ancestors: nearest harness name wins =="
# Copied shells under harness-like names: the marker-free case must not borrow
# the developer's own session.
say "the parent decides" \
  "$($CLEAR BIN="$BIN" DET="$TREE" "$BIN/zz-codex-zz" -c 'bash "$BIN/inner.sh" "$DET"; :')" "codex"
say "a grandparent is found through a shell in between" \
  "$($CLEAR BIN="$BIN" DET="$TREE" "$BIN/zz-opencode-zz" -c 'bash -c "bash \"$BIN/inner.sh\" \"$DET\"; :"; :')" "opencode"
say "the nearest harness outvotes an inherited marker" \
  "$($CLEAR OMPCODE=1 CLAUDECODE=1 BIN="$BIN" DET="$TREE" "$BIN/zz-codex-zz" -c 'bash "$BIN/inner.sh" "$DET"; :')" "codex"
# An ancestor-free run exists only outside every harness; asserting it inside
# one would just be asserting the developer's own session.
outer="$(run host_detect)"
if [ "$outer" = unknown ]; then
  say "unknown when no ancestor matches" \
    "$($CLEAR BIN="$BIN" DET="$TREE" "$BIN/zz-neutral" -c 'bash "$BIN/inner.sh" "$DET"; :')" "unknown"
else
  echo "  skip unknown case (this suite runs inside $outer)"
fi

echo "== the probe prints the line =="
say "probe prints host: omp under OMPCODE=1" \
  "$($CLEAR OMPCODE=1 MULTI_HOME="$home" "$TREE/scripts/probe.sh" 2>/dev/null | grep -c '^host: omp$')" "1"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
