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

SCOPE=uncommitted; REF=""; EFFORT=low; OUT=""; CONTEXT=""; ADVERSARIAL=0; MODEL=""; PATHS=""; FOCUS_TEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --paths) PATHS="$2"; shift 2 ;;
    --focus) FOCUS_TEXT="$2"; shift 2 ;;
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

# Narrowing to specific paths is prompt text here, not a flag: `codex exec
# review` discovers the diff itself and takes no pathspec.
if [ -n "$PATHS" ]; then
  SCOPE_LINE="$SCOPE_LINE Of those changes, review ONLY the ones in these paths, and ignore every changed file outside them: $PATHS"
fi

if [ "$ADVERSARIAL" = "1" ]; then
  ANGLE="Do NOT hunt for line-level defects — another reviewer already does that. Challenge the APPROACH: is this the right design for the problem, what unstated assumptions does it rest on, how does it fail under concurrency, retries, partial failure, or scale, and what will be expensive to undo later. Anchor every point to a real file and line in the change."
else
  ANGLE="Hunt for real defects on the CHANGED lines."
fi


FOCUS=""
if [ -n "$FOCUS_TEXT" ]; then
  FOCUS="

What the user asked for, in their own words. It does not replace the review —
still do the whole thing — but it is what they care about most, so lead with it
and answer it explicitly, even if the answer is that it looks fine here:

$FOCUS_TEXT"
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

Report everything you would raise in a real review: logic bugs, security holes,
data loss or corruption, resource leaks, broken error handling, race
conditions, violations of the project rules below — and the small stuff too,
style, naming, a missing test, a nitpick. Rank the small stuff last, at P3,
rather than leaving it out: a minor point that turns out to matter is a worse
loss than a line the reader skips.

The one thing to leave out is pre-existing problems on lines this change did
not touch. Do not run the build or the test suite. If the change really is
clean, say so — that is a valid and often correct answer.${FOCUS}${CTX}"

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
