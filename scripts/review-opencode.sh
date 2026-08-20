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
    uncommitted) HOW="Run this to see it: git diff${PS} && git diff --cached${PS}   (do NOT list the working tree yourself -- new files reach you only through the line below)$(multi_untracked_note "$PATHS")" ;;
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
order, \"this could be cleaner\", blanket \"add tests\". A separate simplicity
reviewer runs on this same target and owns all of that.

${SCOPE_RULE} Do not run the build or the tests.

Output ONLY finding lines, nothing before or after, one per line, exactly:
FILE:LINE | HIGH|MEDIUM|LOW | what is wrong and the concrete case where it bites

If nothing is genuinely wrong, output exactly: No issues found.${FOCUS}${CTX}"

# --format json, not the terminal transcript. The transcript interleaves the
# model's answer with every file it opened, and no amount of grepping tells the
# two apart -- on 2026-08-20 this file was the review target, the model reported
# nothing, and the parser handed the judge two "findings" that were comments
# read out of this very script. The JSON events keep them apart by construction:
# `text` is what the model said, `tool_use` is what it did.
RAW="${OUT}.jsonl"

attempt() { # attempt <model> ; leaves the events in $RAW
  multi_timeout "$MULTI_REVIEW_TIMEOUT" opencode run --pure --auto --format json \
    -m "$1" \
    ${AGENT:+--agent "$AGENT"} \
    --dir . \
    "$PROMPT" > "$RAW" 2>&1
}

# 0 = there is an answer, 3 = the model said nothing, 2 = not JSON at all
# (an opencode older than --format json), 4 = no python to read it with.
render() {
  local py; py="$(multi_python)" || return 4
  "$py" "$SELF_DIR/opencode-report.py" "$RAW" \
    --out "$OUT" --calls "${OUT}.calls" --model "$1" 2>/dev/null
}

attempt "$MODEL"; rc=$?
USED="$MODEL"
render "$USED"; rrc=$?

# No answer means the run did not happen: exhausted usage, an expired
# subscription, a model that reads files until it runs out. There is no way to
# ask the CLI about remaining quota beforehand, so this is where we find out --
# retry once on the free fallback, and only then give up.
if [ "$rrc" = 3 ] && [ -n "$FALLBACK" ] && [ "$FALLBACK" != "$MODEL" ]; then
  echo "[multi] $MODEL produced no answer (exit $rc) — retrying on $FALLBACK" >&2
  cp "$RAW" "${RAW}.first" 2>/dev/null
  attempt "$FALLBACK"; rc=$?
  USED="$FALLBACK"
  render "$USED"; rrc=$?
fi

if [ "$rc" -eq 124 ]; then
  # A timeout can still leave a partial report; keep it, but never let it read
  # as a completed review.
  # `cat` last inside the group would decide the group's exit status, and an
  # absent partial report would then skip the mv and leave $OUT empty -- the
  # one state that reads as "no issues found".
  { echo "opencode: TIMEOUT after ${MULTI_REVIEW_TIMEOUT}s — model=$USED, the review was cut off"
    if [ -s "$OUT" ]; then
      echo "What it had done up to that point:"
      cat "$OUT"
    fi
  } > "${OUT}.tmp"
  mv "${OUT}.tmp" "$OUT"
elif [ "$rrc" = 3 ]; then
  echo "opencode: NO ANSWER — model=$USED exit=$rc — it ran but never wrote a review; what it did is in ${OUT}.calls" > "$OUT"
elif [ "$rrc" = 2 ] || [ "$rrc" = 4 ]; then
  # Either this opencode predates --format json, or there is no python3 here.
  # Fall back to what was captured, prefixed so that a line the model merely
  # READ cannot be mistaken for a finding: a finding starts with a path, and
  # "raw|" is not one.
  why="an opencode without --format json"; [ "$rrc" = 4 ] && why="no python3 on this machine"
  { echo "opencode: RAW CAPTURE ONLY — model=$USED exit=$rc ($why)"
    echo "Below is its output as captured, quoted as prose and NOT as findings —"
    echo "it also contains whatever files the model opened. Full capture: $RAW"
    echo "--- last 80 lines, each prefixed 'raw|' ---"
    tail -n 80 "$RAW" 2>/dev/null | sed "s/$(printf '\033')\[[0-9;]*[a-zA-Z]//g" | sed 's/^/raw| /'
  } > "$OUT"
elif [ ! -s "$OUT" ]; then
  echo "opencode: NO OUTPUT — model=$USED exit=$rc — see $RAW" > "$OUT"
fi

[ "$USED" = "$MODEL" ] || echo "[multi] reviewed by fallback model $USED" >> "$OUT"
exit $rc
