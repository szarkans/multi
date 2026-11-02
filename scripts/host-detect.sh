#!/usr/bin/env bash
# Which harness is running this skill. Sourced by probe.sh; the line it prints
# is `host:`, and the skills name their own command per host from it.
#
# Two sources, in this order:
#
# 1. The nearest process above us whose name is a harness (host_from_ancestors).
#    Environment markers are inherited all the way down — an OpenCode session
#    started from an omp session carries OMPCODE=1 and every shell it spawns
#    passes it on — so the markers alone cannot say which harness is reading
#    this. The ancestor chain can: walk up until a known name appears.
# 2. Markers the harnesses set for their children, most specific first
#    (host_from_markers). These are the variables this repository already
#    relies on (scripts/run-dir.sh reads CODEX_THREAD_ID and OPENCODE_PID),
#    plus the ones the harnesses are known to export. OMPCODE comes before
#    CLAUDECODE because an omp session carries both and must answer `omp`.
#
# Split into two functions so each source can be tested on its own: a test that
# runs inside a harness can never reach the marker branch through host_detect.
host_from_ancestors() {
  local pid="${PPID:-0}" comm hops=0
  while [ "$hops" -lt 8 ] && [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$comm" in
      *opencode*) printf '%s\n' opencode; return 0 ;;
      *omp*) printf '%s\n' omp; return 0 ;;
      *codex*) printf '%s\n' codex; return 0 ;;
      *claude*) printf '%s\n' claude-code; return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    hops=$((hops + 1))
  done
  return 1
}

host_from_markers() {
  if [ -n "${OPENCODE_PID:-}" ]; then printf '%s\n' opencode; return 0; fi
  if [ -n "${CODEX_THREAD_ID:-}" ]; then printf '%s\n' codex; return 0; fi
  if [ "${OMPCODE:-}" = 1 ]; then printf '%s\n' omp; return 0; fi
  if [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ "${CLAUDECODE:-}" = 1 ]; then printf '%s\n' claude-code; return 0; fi
  # Exported in a user's shell profile, so these two only answer when nothing
  # more specific did: CODEX_HOME in a Claude session is not a Codex session.
  if [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_HOME:-}" ]; then printf '%s\n' codex; return 0; fi
  return 1
}

host_detect() {
  host_from_ancestors || host_from_markers || printf '%s\n' unknown
}
