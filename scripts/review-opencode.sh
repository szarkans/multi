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

SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=providers.sh
. "$SELF_DIR/providers.sh"   # multi_timeout, MULTI_REVIEW_TIMEOUT

TARGET=""; DIFF=""; OUT=""; CONTEXT=""; MODEL="${MULTI_OPENCODE_MODEL:-}"; AGENT=""; PATHS=""; FOCUS_TEXT=""; FALLBACK=""
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
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
[ -n "$TARGET" ] || { echo "--target is required" >&2; exit 2; }
[ -n "$MODEL" ] || { echo "no model: set --model or MULTI_OPENCODE_MODEL" >&2; exit 2; }
case "$DIFF" in -*) echo "--diff must be a revision, not an option: $DIFF" >&2; exit 2 ;; esac
[ -z "$PATHS" ] || multi_check_paths "$PATHS" || exit 2

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

# The markers carry a per-run token, and that is the point. OpenCode echoes
# every file it reads into the transcript, so a fixed marker -- or the finding
# pattern itself -- also appears in whatever source file happens to contain it.
# Measured here on 2026-08-20: this script was the file under review, the model
# returned no findings at all, and the parser handed the judge two lines that
# were the comment "# Findings look like: path/file.py:12 | HIGH | why" read
# out of this very file. A token minted per run cannot be in any file on disk.
MARK_TOKEN="$$$RANDOM"
BEGIN_MARK="MULTI-FINDINGS-${MARK_TOKEN}-BEGIN"
END_MARK="MULTI-FINDINGS-${MARK_TOKEN}-END"

PROMPT="You are a code reviewer. ${TARGET_LINE}

Report everything you would raise: logic bugs, security holes, data loss,
resource leaks, unhandled errors, race conditions, violations of the project
rules below. Small defects count too, marked LOW — a wrong id in a log line, an
edge case that bites once a year. Losing one because it looked minor is worse
than a line the reader skips.

Matters of taste do NOT count, at any severity: formatting, naming, import
order, \"this could be cleaner\", blanket \"add tests\". A separate simplicity
reviewer runs on this same target and owns all of that.

${SCOPE_RULE} Do not run the build or the tests.

Put your answer between these two marker lines, each alone on its line, and put
nothing else between them:
${BEGIN_MARK}
FILE:LINE | HIGH|MEDIUM|LOW | what is wrong and the concrete case where it bites
${END_MARK}

One finding per line, in exactly that shape. If nothing is genuinely wrong, put
the single line: No issues found${FOCUS}${CTX}"

# OpenCode echoes every tool call and its output, so a review arrives wrapped in
# the files it read. Keep the whole transcript next to the result for auditing,
# but hand the judge only the finding lines.
RAW="${OUT}.raw"

# Findings look like: path/file.py:12 | HIGH | why
FINDING_RE='^[^|]*:[0-9]+[^|]*\|[[:space:]]*(HIGH|MEDIUM|LOW)[[:space:]]*\|'

ESC="$(printf '\033')"

# Everything downstream reads THIS, never the raw transcript: only the text the
# model put between its own markers. A transcript is full of other people's
# lines -- files it opened, tool output, this script's own comments -- and any
# of them can look exactly like a finding.
answer() {
  sed "s/${ESC}\[[0-9;]*[a-zA-Z]//g" "$RAW" 2>/dev/null | awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { buf=""; inb=1; next }
    index($0, e) { inb=0; next }
    inb { buf = buf $0 "\n" }
    END { printf "%s", buf }'
}

# Timed out because the skill promises a kill-and-restart and nothing here
# delivered one: a hung `opencode run` wrote nothing and the skill waited on a
# file that was never coming. The retry below already handles "produced
# nothing", so a killed attempt lands in the same path a dead one does.
attempt() { # attempt <model> ; leaves the transcript in $RAW
  multi_timeout "$MULTI_REVIEW_TIMEOUT" opencode run --pure --auto \
    -m "$1" \
    ${AGENT:+--agent "$AGENT"} \
    --dir . \
    "$PROMPT" > "$RAW" 2>&1
}

usable() { answer | grep -qaiE "$FINDING_RE" || answer | grep -qai 'No issues found'; }

attempt "$MODEL"; rc=$?
USED="$MODEL"

# Neither findings nor a clean verdict means the run did not happen: exhausted
# usage, an expired subscription, a model that hangs. There is no way to ask
# either CLI about remaining quota beforehand, so this is where we find out —
# retry once on the free fallback, and only then give up.
if ! usable && [ -n "$FALLBACK" ] && [ "$FALLBACK" != "$MODEL" ]; then
  echo "[multi] $MODEL produced nothing (exit $rc) — retrying on $FALLBACK" >&2
  cp "$RAW" "${RAW}.first" 2>/dev/null
  attempt "$FALLBACK"; rc=$?
  USED="$FALLBACK"
fi

SECTION="$(answer)"
printf '%s' "$SECTION" | grep -aiE "$FINDING_RE" > "$OUT"

if [ -s "$OUT" ]; then
  # Whatever else sits between the markers is still the reviewer talking. A
  # finding written as prose next to three well-formed ones used to vanish with
  # no trace at all, so count it and point at the transcript.
  extra="$(printf '%s' "$SECTION" | grep -aviE "$FINDING_RE" | grep -cv '^[[:space:]]*$')"
  [ "${extra:-0}" -eq 0 ] || \
    echo "[multi] $extra more line(s) between the markers were not in finding format — read them in $RAW" >> "$OUT"
elif printf '%s' "$SECTION" | grep -qai 'No issues found'; then
  echo "No issues found." > "$OUT"
elif [ "$rc" -eq 124 ]; then
  echo "opencode: TIMEOUT after ${MULTI_REVIEW_TIMEOUT}s — model=$USED, no review was produced — see $RAW" > "$OUT"
elif [ -s "$RAW" ]; then
  # The model produced something but never marked an answer -- it drifted off
  # format, or stopped after reading files. Hand the judge the tail of the
  # transcript, clearly labelled: it is prose at best, and at worst it is other
  # people's lines, because a transcript carries every file the model opened.
  {
    echo "opencode: NO MARKED ANSWER — model=$USED exit=$rc"
    echo "The model never produced its answer between the markers it was given. What"
    echo "follows is the tail of its transcript, quoted as prose and NOT as findings:"
    echo "it also contains files the model read, so confirm anything you take from it."
    echo "Full transcript: $RAW"
    echo "--- last 80 transcript lines, each prefixed 'raw|' ---"
    # The prefix is load-bearing, and it contains a pipe on purpose: a finding
    # line is "path:line | SEVERITY | why", so anything whose first field is
    # already "raw" cannot be read as one. A plain "raw> " prefix does not do
    # it -- "raw> src/x.py:99 | HIGH | ..." still matches the finding shape.
    tail -n 80 "$RAW" | sed "s/${ESC}\[[0-9;]*[a-zA-Z]//g" | sed 's/^/raw| /' 
  } > "$OUT"
else
  echo "opencode: NO OUTPUT — model=$USED exit=$rc — see $RAW" > "$OUT"
fi
[ "$USED" = "$MODEL" ] || echo "[multi] reviewed by fallback model $USED" >> "$OUT"
exit $rc
