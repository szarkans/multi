#!/usr/bin/env bash
# Recall harness for the external reviewers.
#
#   run.sh --repo <path-to-corpus-repo> --out <results-dir> [--case <id>]
#          [--effort low|medium|high] [--model <opencode-model>] [--no-context]
#
# For every case in cases.tsv: check the repo out at the fix commit in a
# throwaway worktree, revert the fix in the listed source files, and run each
# external reviewer over the resulting diff. Grading is not automated on
# purpose — a human or a judge model compares each reviewer's output against
# the case's ground truth, because "did it find THIS bug" is a judgement call
# that a substring match gets wrong in both directions.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"

REPO=""; OUT=""; ONLY=""; EFFORT=low; OC_MODEL="${MCR_OPENCODE_MODEL:-opencode/deepseek-v4-flash-free}"; USE_CTX=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --case) ONLY="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --model) OC_MODEL="$2"; shift 2 ;;
    --no-context) USE_CTX=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$OUT" ] || { echo "usage: run.sh --repo <path> --out <dir> [--case id]" >&2; exit 2; }
mkdir -p "$OUT"

WT_ROOT="$OUT/worktrees"; mkdir -p "$WT_ROOT"

# Read the case list on fd 3, not stdin: the reviewers we spawn below inherit
# stdin and would otherwise swallow the remaining cases, silently reviewing
# only the first one.
while IFS=$'\t' read -r -u 3 id sha paths truth; do
  case "$id" in ''|\#*) continue ;; esac
  [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue

  wt="$WT_ROOT/$id"
  rm -rf "$wt"
  git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1
  if ! git -C "$REPO" worktree add --detach "$wt" "$sha" >/dev/null 2>&1; then
    echo "[$id] SKIP: cannot create worktree at $sha" >&2; continue
  fi

  # Undo the fix in source files only; tests and docs stay fixed and stay out
  # of the diff, so nothing in the change hints at the answer.
  reverted=0
  for p in $paths; do
    if git -C "$wt" checkout "${sha}^" -- "$p" 2>/dev/null; then reverted=$((reverted+1)); fi
  done
  if [ "$reverted" = 0 ]; then
    echo "[$id] SKIP: nothing reverted (paths may not exist before $sha)" >&2; continue
  fi
  if [ -z "$(git -C "$wt" status --porcelain)" ]; then
    echo "[$id] SKIP: revert produced an empty diff" >&2; continue
  fi

  printf '%s\n' "$truth" > "$OUT/$id.truth.txt"
  git -C "$wt" diff --cached > "$OUT/$id.diff.txt"

  ctx_arg=()
  if [ "$USE_CTX" = 1 ]; then
    ( cd "$wt" && bash "$SCRIPTS/collect-context.sh" --scope uncommitted ) > "$OUT/$id.ctx.md" 2>/dev/null
    [ -s "$OUT/$id.ctx.md" ] && ctx_arg=(--context "$OUT/$id.ctx.md")
  fi

  echo "[$id] reviewing ($(wc -l < "$OUT/$id.diff.txt") diff lines)"

  ( cd "$wt" && bash "$SCRIPTS/review-codex.sh" --scope uncommitted --effort "$EFFORT" \
      "${ctx_arg[@]}" --out "$OUT/$id.codex.txt" ) > "$OUT/$id.codex.log" 2>&1 &
  cx=$!
  ( cd "$wt" && bash "$SCRIPTS/review-opencode.sh" --scope uncommitted --model "$OC_MODEL" \
      "${ctx_arg[@]}" --out "$OUT/$id.opencode.txt" ) > "$OUT/$id.opencode.log" 2>&1 &
  oc=$!
  wait $cx; echo "[$id] codex done"
  wait $oc; echo "[$id] opencode done"
done 3< "$HERE/cases.tsv"

echo
echo "results in $OUT — compare each <id>.codex.txt / <id>.opencode.txt against <id>.truth.txt"
