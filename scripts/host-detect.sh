#!/usr/bin/env bash
# Which harness is running this skill. Sourced by probe.sh; the line it prints
# is `host:`, and the skills name their own command per host from it.
#
# Order matters. An omp session carries OMPCODE=1 and often CLAUDECODE=1 too
# (it imports Claude sessions), so omp is checked first. CODEX_HOME comes after
# CLAUDECODE for the same reason: a variable exported in the user's shell must
# not outvote the marker of the harness that is actually running.
host_detect() {
  if [ "${OMPCODE:-}" = 1 ]; then printf '%s\n' omp; return; fi
  if [ "${OPENCODE:-}" = 1 ]; then printf '%s\n' opencode; return; fi
  if [ "${CLAUDECODE:-}" = 1 ]; then printf '%s\n' claude-code; return; fi
  if [ -n "${CODEX_HOME:-}" ] || [ -n "${CODEX_SANDBOX:-}" ]; then printf '%s\n' codex; return; fi
  parent="$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || true)"
  case "$parent" in
    *omp*) printf '%s\n' omp ;;
    *opencode*) printf '%s\n' opencode ;;
    *codex*) printf '%s\n' codex ;;
    *claude*) printf '%s\n' claude-code ;;
    *) printf '%s\n' unknown ;;
  esac
}
