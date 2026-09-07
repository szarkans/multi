#!/usr/bin/env bash
# Block until every backend of one ask.sh run has finished, then say how each
# one ended. The judge calls this once instead of guessing from an empty file:
# a backend can be twenty minutes into a review with nothing written yet, and
# "empty .txt" used to be read as "did not answer" (#27).
#
#   wait.sh --prefix "$RUN/review"              wait for all of them
#   wait.sh --prefix "$RUN/review" --max 540    give up waiting after 540s
#
# Prints one line per backend:
#   codex       5m12s   ok
#   glm         23m04s  ok
#   openrouter  40m00s  FAILED: openrouter: TIMEOUT after 2400s — ...
#   glm         9m30s   still running (timeout 2400s)      <- only with --max
# Exit 0 when nothing is running any more, 1 when --max ran out first (call
# again), 2 on a bad prefix. A Bash tool call is capped at ten minutes, so
# --max 540 and a re-call is how a forty-minute review is waited for.
#
# The roster is <prefix>.run, written by ask.sh before it launches anything:
# one "<backend>" line per participant, then "<backend> <seconds>" as each
# ends. Status comes from that file and the .running/.dead sidecars -- never
# from the text of an answer, and never from a glob: "review-*" would also
# match a "review-2" run beside it.
set -uo pipefail

PREFIX=""; MAX=""
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) need $# "$1"; PREFIX="$2"; shift 2 ;;
    --max)    need $# "$1"
              case "$2" in ''|*[!0-9]*|0) echo "--max must be a positive integer: $2" >&2; exit 2 ;; esac
              MAX="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PREFIX" ] || { echo "--prefix is required" >&2; exit 2; }
case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac
ROSTER="${PREFIX}.run"
# ask.sh spends its first second resolving the config before it writes the
# roster, and the skills call this right after launching it: give it a moment.
n=0; while [ ! -s "$ROSTER" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n+1)); done
[ -s "$ROSTER" ] || { echo "wait.sh: no roster at $ROSTER — wrong --prefix, or ask.sh has not started (an ask.sh older than 1.11 writes none)" >&2; exit 2; }

# The participants: roster lines with one field. Order preserved.
roster() { awk 'NF==1 && !seen[$1]++ {print $1}' "$ROSTER"; }

# A marker is live when the pid in it -- the backend's own runner, which
# outlives a SIGKILLed ask.sh -- still exists. Read once: the runner may remove
# the file between a test and a read, and a second read would then leave the
# fields unset under set -u.
RPID=""; RSTART=""; RTIMEOUT=""
read_marker() { # read_marker <running-file> -> 0 and RPID/RSTART/RTIMEOUT when it is live
  RPID=""; RSTART=""; RTIMEOUT=""
  [ -e "$1" ] || return 1
  read -r RPID RSTART RTIMEOUT 2>/dev/null < "$1" || return 1
  case "$RPID" in ''|*[!0-9]*) RPID=""; return 1 ;; esac
  kill -0 "$RPID" 2>/dev/null || { RPID=""; return 1; }
}
any_running() {
  local b
  for b in $(roster); do
    read_marker "${PREFIX}-${b}.txt.running" && return 0
  done
  return 1
}

t0="$(date +%s)"
while any_running; do
  if [ -n "$MAX" ] && [ $(( $(date +%s) - t0 )) -ge "$MAX" ]; then break; fi
  sleep 2
done

fmt() { # fmt <seconds> -> 5m12s / 42s
  local s="$1"
  [ "$s" -ge 60 ] && printf '%dm%02ds' $((s/60)) $((s%60)) || printf '%ds' "$s"
}
now="$(date +%s)"; rc=0
for b in $(roster); do
  f="${PREFIX}-${b}.txt"
  # Marker first, duration second: a backend that ends between the two would
  # otherwise be seen with no marker and no duration -- "killed".
  if read_marker "${f}.running"; then
    took=""
  else
    took="$(awk -v s="$b" 'NF==2 && ($1 "")==(s "") {print $2; exit}' "$ROSTER")"   # string compare: "01" is not "1"
    [ -z "$took" ] || took="$(fmt "$took")"
  fi
  if [ -n "$RPID" ]; then
    case "$RSTART" in ''|*[!0-9]*) RSTART="$now" ;; esac
    printf '%-12s %-8s still running (timeout %ss)\n' "$b" "$(fmt $((now-RSTART)))" "${RTIMEOUT:-?}"
    rc=1
  elif [ -e "${f}.dead" ]; then
    printf '%-12s %-8s FAILED: %s\n' "$b" "${took:--}" "$(head -1 "${f}.dead")"
  elif [ -e "${f}.running" ] || [ -z "$took" ]; then
    # A marker nobody owns, or no "done" line: the runner never reached its
    # end. Whatever is in the answer file was cut off. (ask.sh's own TERM/INT
    # trap writes KILLED markers; only SIGKILL gets here.)
    printf '%-12s %-8s FAILED: killed before it finished — no .dead marker; the answer file, if any, is partial\n' "$b" "${took:--}"
  elif [ -s "$f" ]; then
    printf '%-12s %-8s ok\n' "$b" "$took"
  else
    printf '%-12s %-8s FAILED: finished with no answer and no marker\n' "$b" "$took"
  fi
done
exit "$rc"
