#!/usr/bin/env bash
# Recall harness for the external reviewers.
#
#   run.sh --repo <path-to-corpus-repo> --out <results-dir> [--case <id>]
#          [--cases <file>] [--prep-only] [--mode revert|blind|intro]
#          [--effort low|medium|high]
#          [--model <opencode-model>] [--backend <spec>] [--no-context]
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

REPO=""; OUT=""; ONLY=""; CASES="$HERE/cases.tsv"; CUSTOM_CASES=0; PREP_ONLY=0
MODE=revert; EFFORT=low; OC_MODEL=""; BACKEND=""; USE_CTX=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --case) ONLY="$2"; shift 2 ;;
    --cases) CASES="$2"; CUSTOM_CASES=1; shift 2 ;;
    --prep-only) PREP_ONLY=1; shift ;;
    --mode) MODE="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --model) OC_MODEL="$2"; shift 2 ;;   # opencode model for the DEFAULT backend list; ignored with --backend
    --backend) BACKEND="$2"; shift 2 ;;
    --no-context) USE_CTX=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# Default: codex + opencode as before; an explicit --model pins the opencode
# one, otherwise the config's chain (or the catalogue auto-pick) applies.
if [ -n "$BACKEND" ]; then
  [ -z "$OC_MODEL" ] || echo "warning: --model is ignored with --backend; pin it there as opencode:$OC_MODEL" >&2
else
  BACKEND="codex,opencode${OC_MODEL:+:$OC_MODEL}"
fi
case "$MODE" in revert|blind|intro) ;; *) echo "--mode must be revert, blind, or intro" >&2; exit 2 ;; esac
[ -n "$OUT" ] && { [ "$CUSTOM_CASES" = 1 ] || [ -n "$REPO" ]; } || {
  echo "usage: run.sh --repo <path> --out <dir> [--case id] [--cases file] [--prep-only] [--mode revert|blind|intro]" >&2; exit 2
}
mkdir -p "$OUT" || exit 2
OUT="$(cd "$OUT" && pwd)" || exit 2

WT_ROOT="$OUT/worktrees"; mkdir -p "$WT_ROOT"

# Read the case list on fd 3, not stdin: the reviewers we spawn below inherit
# stdin and would otherwise swallow the remaining cases, silently reviewing
# only the first one.
while :; do
  if [ "$CUSTOM_CASES" = 1 ]; then
    IFS=$'\t' read -r -u 3 id case_repo sha paths truth intro_sha || break
  else
    IFS=$'\t' read -r -u 3 id sha paths truth || break
    case_repo="$REPO"
    intro_sha=""
  fi
  case "$id" in ''|\#*) continue ;; esac
  [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue
  if [ "$MODE" = intro ] && [ -z "$intro_sha" ]; then
    echo "[$id] SKIP: no intro sha" >&2; continue
  fi
  if [ ! -d "$case_repo" ]; then
    echo "[$id] SKIP: repo not found $case_repo" >&2; continue
  fi

  worktree_ref="$sha"
  [ "$MODE" != blind ] || worktree_ref="${sha}^"
  [ "$MODE" != intro ] || worktree_ref="$intro_sha"
  wt="$WT_ROOT/$id"
  rm -rf "$wt"
  git -C "$case_repo" worktree remove --force "$wt" >/dev/null 2>&1
  if ! git -C "$case_repo" worktree add --detach "$wt" "$worktree_ref" >/dev/null 2>&1; then
    echo "[$id] SKIP: cannot create worktree at $worktree_ref" >&2; continue
  fi

  if [ "$MODE" = intro ]; then
    intro_base="${intro_sha}^"
    if ! git -C "$wt" rev-parse --verify -q "${intro_sha}^" >/dev/null; then
      intro_base="$(git -C "$wt" hash-object -t tree /dev/null)"
    fi
    intro_diff="${intro_base}..${intro_sha}"
  fi

  if [ "$MODE" = revert ]; then
    # The worktree baseline must not contain answer-bearing fix scaffolding.
    fix_files="$(git -C "$wt" diff --name-only "${sha}^" "$sha")"
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      is_source=0
      for p in $paths; do
        if [ "$file" = "$p" ]; then is_source=1; break; fi
      done
      [ "$is_source" = 0 ] || continue
      if git -C "$wt" cat-file -e "${sha}^:$file" 2>/dev/null; then
        git -C "$wt" checkout "${sha}^" -- "$file"
      else
        git -C "$wt" rm -q -f -- "$file"
      fi
    done <<< "$fix_files"
    if ! git -C "$wt" diff --cached --quiet; then
      git -C "$wt" -c user.name='multi eval' -c user.email='multi-eval@localhost' \
        commit -q -m "descaffold fix commit"
    fi

    # Only source paths belong in the reviewer diff.
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
  fi

  printf '%s\n' "$truth" > "$OUT/$id.truth.txt"
  if [ "$MODE" = revert ]; then
    git -C "$wt" diff --cached > "$OUT/$id.diff.txt"
  elif [ "$MODE" = intro ]; then
    git -C "$wt" diff "$intro_base" "$intro_sha" > "$OUT/$id.diff.txt"
  fi

  if [ "$PREP_ONLY" = 1 ]; then
    case "$MODE" in
      revert) echo "[$id] prepared: $(wc -l < "$OUT/$id.diff.txt") diff lines, worktree $wt" ;;
      blind) echo "[$id] prepared (blind): worktree $wt" ;;
      intro) echo "[$id] prepared (intro): $(wc -l < "$OUT/$id.diff.txt") diff lines, worktree $wt" ;;
    esac
    continue
  fi

  ctx_arg=()
  if [ "$USE_CTX" = 1 ]; then
    case "$MODE" in
      revert) ( cd "$wt" && bash "$SCRIPTS/collect-context.sh" --diff uncommitted ) > "$OUT/$id.ctx.md" 2>/dev/null ;;
      blind) ( cd "$wt" && bash "$SCRIPTS/collect-context.sh" ) > "$OUT/$id.ctx.md" 2>/dev/null ;;
      intro) ( cd "$wt" && bash "$SCRIPTS/collect-context.sh" --diff "$intro_diff" ) > "$OUT/$id.ctx.md" 2>/dev/null ;;
    esac
    [ -s "$OUT/$id.ctx.md" ] && ctx_arg=(--context "$OUT/$id.ctx.md")
  fi

  if [ "$MODE" = blind ]; then
    echo "[$id] reviewing (blind)"
  else
    echo "[$id] reviewing ($(wc -l < "$OUT/$id.diff.txt") diff lines)"
  fi

  case "$MODE" in
    revert) ( cd "$wt" && bash "$SCRIPTS/review-prompt.sh" --target "the uncommitted changes" --diff uncommitted \
        ${ctx_arg[@]+"${ctx_arg[@]}"} ) > "$OUT/$id.prompt.md" ;;
    blind) ( cd "$wt" && bash "$SCRIPTS/review-prompt.sh" --target "the code in this working tree" --paths "$paths" \
        ${ctx_arg[@]+"${ctx_arg[@]}"} ) > "$OUT/$id.prompt.md" ;;
    intro) ( cd "$wt" && bash "$SCRIPTS/review-prompt.sh" --target "this commit" --diff "$intro_diff" \
        ${ctx_arg[@]+"${ctx_arg[@]}"} ) > "$OUT/$id.prompt.md" ;;
  esac
  ( cd "$wt" && bash "$SCRIPTS/ask.sh" --question-file "$OUT/$id.prompt.md" --out-prefix "$OUT/$id" \
      --backend "$BACKEND" --effort "$EFFORT" --timeout "${MULTI_REVIEW_TIMEOUT:-2400}" \
  ) > "$OUT/$id.ask.log" 2>&1
  echo "[$id] reviewers done: $(ls "$OUT/$id"-*.txt 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
done 3< "$CASES"

echo
echo "results in $OUT — compare each <id>-codex.txt / <id>-opencode.txt against <id>.truth.txt"
