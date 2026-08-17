#!/usr/bin/env bash
# Put one question to Codex and OpenCode at the same time and write each answer
# to its own file. No review prompt, no parsing, no judging — whatever the
# question is, the answers come back raw.
#
#   ask.sh --question "is a channel or a mutex better here?" --out-prefix /tmp/multi-ask
#   ask.sh --question-file /tmp/prompt.md --out-prefix /tmp/multi-done --effort high
#
# Writes:
#   <prefix>-codex.txt      Codex answer
#   <prefix>-opencode.txt   OpenCode answer (or a line saying it did not run)
#
# Both run read-only: they can read the repository to answer, and cannot change
# it. Anything that needs to actually execute is the caller's job.
#
# Notes for maintainers:
#   --pure skips the user's OpenCode plugins and --auto pre-approves tool calls;
#   without them a heavy custom default agent can hang the run indefinitely.
#   OpenCode spends roughly a minute on cold start, so the two backends are
#   always launched together rather than in sequence.
set -uo pipefail

QUESTION=""; QFILE=""; PREFIX=""; EFFORT=medium; MODEL="${MULTI_OPENCODE_MODEL:-}"; FALLBACK=""; CODEX_MODEL=""
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --question)      need $# "$1"; QUESTION="$2"; shift 2 ;;
    --question-file) need $# "$1"; QFILE="$2"; shift 2 ;;
    --out-prefix)    need $# "$1"; PREFIX="$2"; shift 2 ;;
    --effort)        need $# "$1"; EFFORT="$2"; shift 2 ;;
    --model)         need $# "$1"; MODEL="$2"; shift 2 ;;
    --fallback)      need $# "$1"; FALLBACK="$2"; shift 2 ;;
    --codex-model)   need $# "$1"; CODEX_MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PREFIX" ] || { echo "--out-prefix is required" >&2; exit 2; }
if [ -n "$QFILE" ]; then
  [ -z "$QUESTION" ] || { echo "pass --question or --question-file, not both" >&2; exit 2; }
  [ -s "$QFILE" ] || { echo "--question-file is empty or missing: $QFILE" >&2; exit 2; }
  QUESTION="$(cat "$QFILE")"
fi
[ -n "$QUESTION" ] || { echo "--question or --question-file is required" >&2; exit 2; }

CODEX_OUT="${PREFIX}-codex.txt"
OC_OUT="${PREFIX}-opencode.txt"

run_codex() {
  command -v codex >/dev/null 2>&1 || { echo "codex: MISSING" > "$CODEX_OUT"; return 0; }
  codex exec \
    ${CODEX_MODEL:+-m "$CODEX_MODEL"} \
    -s read-only \
    -c model_reasoning_effort="$EFFORT" \
    -o "$CODEX_OUT" \
    "$QUESTION" >/dev/null 2>&1
}

run_opencode() {
  command -v opencode >/dev/null 2>&1 || { echo "opencode: MISSING" > "$OC_OUT"; return 0; }
  [ -n "$MODEL" ] || { echo "opencode: NO MODEL (set --model or MULTI_OPENCODE_MODEL)" > "$OC_OUT"; return 0; }
  local raw="${OC_OUT}.raw" used="$MODEL" rc=0
  opencode run --pure --auto -m "$MODEL" --dir . "$QUESTION" > "$raw" 2>&1; rc=$?
  # An empty transcript means the run never happened — exhausted usage, an
  # expired subscription, a model that hangs. Neither CLI can be asked about
  # remaining quota beforehand, so this is where it is discovered.
  if [ ! -s "$raw" ] && [ -n "$FALLBACK" ] && [ "$FALLBACK" != "$MODEL" ]; then
    echo "[multi] $MODEL produced nothing (exit $rc) — retrying on $FALLBACK" >&2
    opencode run --pure --auto -m "$FALLBACK" --dir . "$QUESTION" > "$raw" 2>&1; rc=$?
    used="$FALLBACK"
  fi
  if [ -s "$raw" ]; then
    cp "$raw" "$OC_OUT"
    [ "$used" = "$MODEL" ] || echo "[multi] answered by fallback model $used" >> "$OC_OUT"
  else
    # Say so explicitly rather than letting an empty file read as an answer.
    echo "opencode: NO OUTPUT — model=$used exit=$rc" > "$OC_OUT"
  fi
}

run_codex & cpid=$!
run_opencode & opid=$!
wait "$cpid"; crc=$?
wait "$opid"

[ -s "$CODEX_OUT" ] || echo "codex: NO OUTPUT — exit=$crc" > "$CODEX_OUT"
echo "wrote: $CODEX_OUT $OC_OUT"
