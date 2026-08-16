#!/usr/bin/env bash
# Run one Codex review pass over a scoped diff and write findings as JSON.
#
#   review-codex.sh --scope uncommitted            --effort low  --out F [--context C]
#   review-codex.sh --scope branch --ref main      --effort high --out F [--context C]
#   review-codex.sh --scope commit --ref <sha>     --effort high --out F [--context C]
#   review-codex.sh ... --adversarial              # challenge the approach, not the lines
#
# Notes for maintainers:
#   `codex exec review` refuses a custom PROMPT together with --uncommitted /
#   --base / --commit, so scope is expressed *inside* the prompt text instead.
#   Default reasoning effort for a custom prompt is `none`, so we always set it.
set -uo pipefail

SCOPE=uncommitted; REF=""; EFFORT=low; OUT=""; CONTEXT=""; ADVERSARIAL=0; MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --adversarial) ADVERSARIAL=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }

case "$SCOPE" in
  uncommitted) SCOPE_LINE="Review ONLY the uncommitted changes in this repository. Find them yourself with: git status --porcelain --untracked-files=all, git diff, git diff --cached. Untracked files count as changes." ;;
  branch)      SCOPE_LINE="Review ONLY the changes this branch adds on top of ${REF}. Find them with: git diff ${REF}...HEAD" ;;
  commit)      SCOPE_LINE="Review ONLY the changes introduced by commit ${REF}. Find them with: git show ${REF}" ;;
  *) echo "unknown scope: $SCOPE" >&2; exit 2 ;;
esac

if [ "$ADVERSARIAL" = "1" ]; then
  ANGLE="Do NOT hunt for line-level defects — another reviewer already does that. Challenge the APPROACH: is this the right design for the problem, what unstated assumptions does it rest on, how does it fail under concurrency, retries, partial failure, or scale, and what will be expensive to undo later. Anchor every point to a real file and line in the change."
else
  ANGLE="Hunt for real defects on the CHANGED lines."
fi

CTX=""
if [ -n "$CONTEXT" ] && [ -s "$CONTEXT" ]; then
  CTX="

Project rules and known gotchas that apply to the changed files — violations of
these are findings, and they override your general priors about this codebase:

$(cat "$CONTEXT")"
fi

PROMPT="You are a senior code reviewer. ${SCOPE_LINE}

${ANGLE}

Report only problems that are genuinely wrong: logic bugs, security holes, data
loss or corruption, resource leaks, broken error handling, race conditions,
violations of the project rules below. Do NOT report: pre-existing problems on
lines this change did not touch, pure style or naming, missing tests, or
anything a linter or type checker already catches. Do not run the build or the
test suite. If nothing is genuinely wrong, return an empty findings list — an
empty list is a valid and often correct answer.${CTX}"

# `codex exec review` ignores --output-schema (the subcommand has its own fixed
# report format), so we take its native text and let the judge read it:
#   - [P1] <title> — <abs/path>:<line>-<line>
#     <explanation>
# P1/P2/P3 map to high/medium/low.
exec codex exec review \
  ${MODEL:+-m "$MODEL"} \
  -c model_reasoning_effort="$EFFORT" \
  -o "$OUT" \
  "$PROMPT"
