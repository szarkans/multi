#!/usr/bin/env bash
# Run one OpenCode review pass over whatever the caller names. Third-reviewer
# slot: any model the user has. Findings come back as one line each,
# `|`-separated.
#
#   review-opencode.sh --target "src/auth.py" --out F
#   review-opencode.sh --target "the uncommitted changes" --diff uncommitted --out F
#   review-opencode.sh --target "this branch vs main" --diff "main...HEAD" --out F
#
# Notes for maintainers:
#   --pure skips the user's OpenCode plugins; --auto pre-approves tool calls so
#   the run never blocks on a prompt. Both are load-bearing: without them a
#   heavy custom default agent can hang the run indefinitely. Roughly a minute
#   of the wall clock is OpenCode's cold start, not the review — always launch
#   this in the background alongside Codex.
set -uo pipefail

TARGET=""; DIFF=""; OUT=""; CONTEXT=""; MODEL="${MCR_OPENCODE_MODEL:-}"; AGENT=""; PATHS=""; FOCUS_TEXT=""; FALLBACK=""
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) need $# "$1"; TARGET="$2"; shift 2 ;;
    --diff) need $# "$1"; DIFF="$2"; shift 2 ;;
    --out) need $# "$1"; OUT="$2"; shift 2 ;;
    --context) need $# "$1"; CONTEXT="$2"; shift 2 ;;
    --model) need $# "$1"; MODEL="$2"; shift 2 ;;
    --agent) need $# "$1"; AGENT="$2"; shift 2 ;;
    --fallback) need $# "$1"; FALLBACK="$2"; shift 2 ;;
    --paths) need $# "$1"; PATHS="$2"; shift 2 ;;
    --focus) need $# "$1"; FOCUS_TEXT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "--target is required" >&2; exit 2; }
[ -n "$MODEL" ] || { echo "no model: set --model or MCR_OPENCODE_MODEL" >&2; exit 2; }
case "$DIFF" in -*) echo "--diff must be a revision, not an option: $DIFF" >&2; exit 2 ;; esac

PS=""
[ -n "$PATHS" ] && PS=" -- $PATHS"

if [ -n "$DIFF" ]; then
  case "$DIFF" in
    uncommitted) HOW="Run this to see it: git status --porcelain --untracked-files=all${PS} && git diff${PS} && git diff --cached${PS}" ;;
    *)           HOW="Run this to see it: git diff ${DIFF}${PS}   (if that is a single commit, use git show ${DIFF}${PS} instead)" ;;
  esac
  TARGET_LINE="Review this change: ${TARGET}
${HOW}"
  SCOPE_RULE="Report what the change introduces. A problem on a line the change did not touch is out of scope here."
else
  TARGET_LINE="Review this: ${TARGET}${PATHS:+
The relevant paths are: $PATHS}
This is not a diff. Read the actual files first — all of them — and follow the
calls outward far enough to know what the code really does before judging it."
  SCOPE_RULE="Everything in the target is in scope, however old it is. Nobody asked what changed recently; they asked what is wrong with this code."
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

Project rules that apply here. Violating one of these IS a finding, and they
override your general priors about this codebase:

$(cat "$CONTEXT")"
fi

PROMPT="You are a code reviewer. ${TARGET_LINE}

Report everything you would raise: logic bugs, security holes, data loss,
resource leaks, unhandled errors, race conditions, violations of the project
rules below. Small defects count too, marked LOW — a wrong id in a log line, an
edge case that bites once a year. Losing one because it looked minor is worse
than a line the reader skips.

Matters of taste do NOT count, at any severity: formatting, naming, import
order, "this could be cleaner", blanket "add tests". A separate simplicity
reviewer runs on this same target and owns all of that.

${SCOPE_RULE} Do not run the build or the tests.

Output ONLY finding lines, nothing before or after, one per line, exactly:
FILE:LINE | HIGH|MEDIUM|LOW | what is wrong and the concrete case where it bites

If nothing is genuinely wrong, output exactly: No issues found.${FOCUS}${CTX}"

# OpenCode echoes every tool call and its output, so a review arrives wrapped in
# the files it read. Keep the whole transcript next to the result for auditing,
# but hand the judge only the finding lines.
RAW="${OUT}.raw"

# Findings look like: path/file.py:12 | HIGH | why
FINDING_RE='^[^|]*:[0-9]+[^|]*\|[[:space:]]*(HIGH|MEDIUM|LOW)[[:space:]]*\|'

attempt() { # attempt <model> ; leaves the transcript in $RAW
  opencode run --pure --auto \
    -m "$1" \
    ${AGENT:+--agent "$AGENT"} \
    --dir . \
    "$PROMPT" > "$RAW" 2>&1
}

usable() { grep -qaiE "$FINDING_RE" "$RAW" || grep -qai 'No issues found' "$RAW"; }

attempt "$MODEL"; rc=$?
USED="$MODEL"

# Neither findings nor a clean verdict means the run did not happen: exhausted
# usage, an expired subscription, a model that hangs. There is no way to ask
# either CLI about remaining quota beforehand, so this is where we find out —
# retry once on the free fallback, and only then give up.
if ! usable && [ -n "$FALLBACK" ] && [ "$FALLBACK" != "$MODEL" ]; then
  echo "[mcr] $MODEL produced nothing (exit $rc) — retrying on $FALLBACK" >&2
  cp "$RAW" "${RAW}.first" 2>/dev/null
  attempt "$FALLBACK"; rc=$?
  USED="$FALLBACK"
fi

grep -aiE "$FINDING_RE" "$RAW" > "$OUT"
if [ ! -s "$OUT" ]; then
  if grep -qai 'No issues found' "$RAW"; then
    echo "No issues found." > "$OUT"
  else
    # Say so explicitly rather than letting an empty file read as "all clear".
    echo "NO PARSEABLE OUTPUT — model=$USED exit=$rc — see $RAW" > "$OUT"
  fi
fi
[ "$USED" = "$MODEL" ] || echo "[mcr] reviewed by fallback model $USED" >> "$OUT"
exit $rc
