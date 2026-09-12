#!/usr/bin/env bash
# Where one run keeps its files. Prints the path, creates it if needed.
#
#   RUN="$(scripts/run-dir.sh --slug skills-fixing-multi)"
#
# Everything lands under one parent, /tmp/multi, rather than scattering
# multi-<uuid> directories across /tmp. A run is named
#
#   <session id>--<slug>       e.g. 940c3630-...-aa25cd613949--skills-fixing-multi
#
# so a directory says whose it is and what it was about, which matters when
# you come back an hour later to read a transcript.
#
# The session id is the identity, the slug is only a label: if this session
# already has a directory, that one is reused whatever slug is passed now.
# Otherwise a caller that phrased the slug slightly differently in a later
# command would start writing into a second directory, and the reviewer
# outputs would end up split across both.
#
# Old runs are deleted here, because nothing else would ever do it.
set -uo pipefail

SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) [ $# -ge 2 ] || { echo "--slug needs a value" >&2; exit 2; }; SLUG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

BASE="${MULTI_RUN_BASE:-${TMPDIR:-/tmp}/multi}"
# MULTI_RUN_ID is the caller's explicit identity and wins. Otherwise the host
# session id: Codex and OpenCode before Claude Code, because a Codex thread or
# an OpenCode run started from inside a Claude session inherits that session's
# id and must not share its run directory (Codex exports a thread id, OpenCode
# its server pid -- one per run, coarser than a session). With none of them a
# bare 'shared' would make every concurrent run collide in one directory.
ID="${MULTI_RUN_ID:-${CODEX_THREAD_ID:-${OPENCODE_PID:+oc-$OPENCODE_PID}}}"
ID="${ID:-${CLAUDE_CODE_SESSION_ID:-shared}}"
mkdir -p "$BASE" 2>/dev/null || { echo "cannot create $BASE" >&2; exit 2; }

# Runs older than this are gone; a transcript nobody opened in a week is not
# going to be opened. MULTI_RUN_KEEP_DAYS=0 turns the sweep off.
KEEP="${MULTI_RUN_KEEP_DAYS:-7}"
if [ "$KEEP" != "0" ]; then
  find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '*--*' -mtime "+${KEEP}" -exec rm -rf {} + 2>/dev/null
fi

# Already have one for this session? Use it, slug or no slug.
for d in "$BASE/$ID"--*; do
  if [ -d "$d" ]; then
    printf '%s' "$d"
    exit 0
  fi
done

# Lower-case, only letters, digits and dashes: this becomes a path.
slug="$(printf '%s' "${SLUG:-run}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
[ -n "$slug" ] || slug="run"

dir="$BASE/${ID}--${slug}"
mkdir -p "$dir" 2>/dev/null || { echo "cannot create $dir" >&2; exit 2; }
printf '%s' "$dir"
