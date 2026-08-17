#!/usr/bin/env bash
# Run one Codex review pass over whatever the caller names, and write the
# findings to --out.
#
#   review-codex.sh --target "src/auth.py and src/session.py" --out F
#   review-codex.sh --target "the uncommitted changes" --diff uncommitted --out F
#   review-codex.sh --target "this branch vs main" --diff "main...HEAD" --out F
#   review-codex.sh --target "the legacy billing module" --paths "legacy/billing" --out F
#   review-codex.sh --target "..." --adversarial   # challenge the approach, not the lines
#
# --target is the only required description: it is what the user asked to have
# reviewed, in their words. --diff is what makes this a *change* review rather
# than a code review, and it switches the whole thing into a different mode —
# see below. --paths narrows to concrete files.
#
# Notes for maintainers:
#   `codex exec review` is a change reviewer: it discovers a diff on its own and
#   has nothing to say about a file that was not touched. So it is used only in
#   diff mode; every other target goes through plain `codex exec`, which will
#   read whatever it is pointed at.
#   `codex exec review` also refuses a custom PROMPT together with --uncommitted
#   / --base / --commit, so the range is expressed inside the prompt text.
#   Default reasoning effort for a custom prompt is `none`, so we always set it.
set -uo pipefail

TARGET=""; DIFF=""; EFFORT=low; OUT=""; CONTEXT=""; ADVERSARIAL=0; MODEL=""; PATHS=""; FOCUS_TEXT=""
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) need $# "$1"; TARGET="$2"; shift 2 ;;
    --diff) need $# "$1"; DIFF="$2"; shift 2 ;;
    --effort) need $# "$1"; EFFORT="$2"; shift 2 ;;
    --out) need $# "$1"; OUT="$2"; shift 2 ;;
    --context) need $# "$1"; CONTEXT="$2"; shift 2 ;;
    --model) need $# "$1"; MODEL="$2"; shift 2 ;;
    --paths) need $# "$1"; PATHS="$2"; shift 2 ;;
    --focus) need $# "$1"; FOCUS_TEXT="$2"; shift 2 ;;
    --adversarial) ADVERSARIAL=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "--target is required" >&2; exit 2; }
case "$DIFF" in -*) echo "--diff must be a revision, not an option: $DIFF" >&2; exit 2 ;; esac

# --- what to look at -----------------------------------------------------
if [ -n "$DIFF" ]; then
  case "$DIFF" in
    uncommitted) HOW="Find it with: git status --porcelain --untracked-files=all, git diff, git diff --cached. Untracked files count as changes." ;;
    *)           HOW="Find it with: git diff ${DIFF} (or git show ${DIFF} if that is a single commit)." ;;
  esac
  TARGET_LINE="Review this change: ${TARGET}. ${HOW}"
  SCOPE_RULE="Report problems the change introduces. A problem on a line the change did not touch is out of scope here — leave it alone."
else
  TARGET_LINE="Review this: ${TARGET}. It is not a diff — read the actual code in full before saying anything about it, following the calls outward far enough to know what the code really does."
  SCOPE_RULE="Everything in the target is in scope, however old it is. Nobody asked what changed recently; they asked what is wrong with this code."
fi

[ -n "$PATHS" ] && TARGET_LINE="$TARGET_LINE Restrict yourself to these paths and ignore everything outside them: $PATHS"

if [ "$ADVERSARIAL" = "1" ]; then
  ANGLE="Do NOT hunt for line-level defects — another reviewer already does that. Challenge the APPROACH: is this the right design for the problem, what unstated assumptions does it rest on, how does it fail under concurrency, retries, partial failure, or scale, and what will be expensive to undo later. Anchor every point to a real file and line."
else
  ANGLE="Hunt for real defects."
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

Project rules and known gotchas that apply here — violations of these are
findings, and they override your general priors about this codebase:

$(cat "$CONTEXT")"
fi

PROMPT="You are a senior code reviewer. ${TARGET_LINE}

${ANGLE}

Report everything you would raise in a real review: logic bugs, security holes,
data loss or corruption, resource leaks, broken error handling, race
conditions, violations of the project rules below. Small defects count too and
go last, at P3 — a wrong id in a log line that will mislead during an incident,
an edge case that bites once a year. Losing one of those because it looked
minor is worse than a line the reader skips.

Matters of taste do NOT count, at any severity: formatting, naming, import
order, "this could be cleaner", "this function is long", blanket "add tests".
A separate simplicity reviewer runs on this same target and owns all of that,
so leaving it out costs nothing. A missing test is a finding only when you can
name the specific path that breaks silently without it.

${SCOPE_RULE}

Do not run the build or the test suite. If it really is clean, say so — that is
a valid and often correct answer.${FOCUS}${CTX}"

# `codex exec review` ignores --output-schema (the subcommand has its own fixed
# report format), so we take its native text and let the judge read it:
#   - [P1] <title> — <abs/path>:<line>-<line>
#     <explanation>
# P1/P2/P3 map to high/medium/low. Plain `codex exec` has no fixed format, so
# the prompt asks for the same shape.
if [ -n "$DIFF" ]; then
  exec codex exec review \
    ${MODEL:+-m "$MODEL"} \
    -c model_reasoning_effort="$EFFORT" \
    -o "$OUT" \
    "$PROMPT"
else
  exec codex exec \
    ${MODEL:+-m "$MODEL"} \
    -s read-only \
    -c model_reasoning_effort="$EFFORT" \
    -o "$OUT" \
    "$PROMPT

Output one block per finding, most severe first, and nothing else:

- [P1|P2|P3] <one sentence: what is wrong> — <path>:<line>
  <the concrete case where it bites>

If there is nothing to report, output exactly: No issues found."
fi
