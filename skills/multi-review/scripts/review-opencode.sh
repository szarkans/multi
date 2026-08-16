#!/usr/bin/env bash
# Run one OpenCode review pass over a scoped diff. Third-reviewer slot: any
# model the user has. Findings come back as one line each, `|`-separated.
#
#   review-opencode.sh --scope uncommitted        --out F [--context C] [--model M]
#   review-opencode.sh --scope branch --ref main  --out F
#   review-opencode.sh --scope commit --ref <sha> --out F
#
# Notes for maintainers:
#   --pure skips the user's OpenCode plugins; --auto pre-approves tool calls so
#   the run never blocks on a prompt. Both are load-bearing: without them a
#   heavy custom default agent can hang the run indefinitely. Roughly a minute
#   of the wall clock is OpenCode's cold start, not the review — always launch
#   this in the background alongside Codex.
set -uo pipefail

SCOPE=uncommitted; REF=""; OUT=""; CONTEXT=""; MODEL="${MCR_OPENCODE_MODEL:-}"; AGENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
[ -n "$MODEL" ] || { echo "no model: set --model or MCR_OPENCODE_MODEL" >&2; exit 2; }

case "$SCOPE" in
  uncommitted) DIFF_CMD="git status --porcelain --untracked-files=all && git diff && git diff --cached" ;;
  branch)      DIFF_CMD="git diff ${REF}...HEAD" ;;
  commit)      DIFF_CMD="git show ${REF}" ;;
  *) echo "unknown scope: $SCOPE" >&2; exit 2 ;;
esac

CTX=""
if [ -n "$CONTEXT" ] && [ -s "$CONTEXT" ]; then
  CTX="

Project rules that apply to the changed files. Violating one of these IS a
finding, and they override your general priors about this codebase:

$(cat "$CONTEXT")"
fi

PROMPT="You are a code reviewer. Run this to see the change under review:
${DIFF_CMD}

Report everything you would raise on the CHANGED lines: logic bugs, security
holes, data loss, resource leaks, unhandled errors, race conditions, violations
of the project rules below — and the small stuff too, style, naming, a missing
test, a nitpick. Mark the small stuff LOW rather than leaving it out; losing a
minor point that turns out to matter is worse than a line the reader skips.

The one thing to leave out is pre-existing problems on untouched lines. Do not
run the build or the tests.

Output ONLY finding lines, nothing before or after, one per line, exactly:
FILE:LINE | HIGH|MEDIUM|LOW | what is wrong and the concrete case where it bites

If nothing is genuinely wrong, output exactly: No issues found.${CTX}"

# OpenCode echoes every tool call and its output, so a review of a 200-line
# diff arrives wrapped in the diff itself. Keep the whole transcript next to
# the result for auditing, but hand the judge only the finding lines.
RAW="${OUT}.raw"
opencode run --pure --auto \
  -m "$MODEL" \
  ${AGENT:+--agent "$AGENT"} \
  --dir . \
  "$PROMPT" > "$RAW" 2>&1
rc=$?

grep -aiE '^[^|]*:[0-9]+[^|]*\|[[:space:]]*(HIGH|MEDIUM|LOW)[[:space:]]*\|' "$RAW" > "$OUT"
if [ ! -s "$OUT" ]; then
  if grep -qai 'No issues found' "$RAW"; then
    echo "No issues found." > "$OUT"
  else
    # Neither findings nor a clean verdict: the run died or drifted off format.
    # Say so explicitly rather than letting an empty file read as "all clear".
    echo "NO PARSEABLE OUTPUT (exit $rc) — see $RAW" > "$OUT"
  fi
fi
exit $rc
