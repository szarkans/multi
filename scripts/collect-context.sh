#!/usr/bin/env bash
# Assemble the project rules that apply to whatever is being reviewed, so that
# EVERY reviewer — Codex, OpenCode, and the Claude sub-agents — sees the same
# gotchas. Without this the external reviewers know nothing about the project's
# conventions and spend their findings re-litigating settled decisions.
#
#   collect-context.sh --paths "src/auth.py src/session.py"   > ctx.md
#   collect-context.sh --diff uncommitted                     > ctx.md
#   collect-context.sh --diff "main...HEAD" --paths "src"     > ctx.md
#   collect-context.sh                                        > ctx.md   (repo canon only)
#
# The file list comes from --paths, from the diff, or from both. With neither,
# only the repo-wide canon is emitted — that is the right answer for "review
# this whole repository", not a failure.
#
# Selection rules:
#   - repo-root CLAUDE.md / AGENTS.md always (they are the project canon)
#   - <repo>/.claude/rules/<name>.md when <name> appears in a relevant path,
#     or all of them when the repo has few enough to fit
#   - nested CLAUDE.md / AGENTS.md living in a directory that is in scope
# Everything is capped so a huge rules tree cannot blow up the reviewer prompts.
set -uo pipefail

DIFF=""; PATHS=""
MAX_TOTAL_BYTES="${MULTI_CONTEXT_MAX_BYTES:-24000}"
MAX_FILE_BYTES="${MULTI_CONTEXT_MAX_FILE_BYTES:-8000}"

need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --diff) need $# "$1"; DIFF="$2"; shift 2 ;;
    --paths) need $# "$1"; PATHS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# A revision starting with "-" is an option to git, not a revision: `--diff
# --output=/etc/passwd` would make `git diff` write to that path. Refuse it.
case "$DIFF" in -*) echo "--diff must be a revision, not an option: $DIFF" >&2; exit 2 ;; esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

# --paths is a whitespace-separated list from the caller; read it into an array
# once so nothing downstream relies on unquoted word splitting.
PATH_ARR=()
[ -n "$PATHS" ] && read -r -a PATH_ARR <<<"$PATHS"

FILES=""
if [ -n "$DIFF" ]; then
  case "$DIFF" in
    uncommitted)
      FILES="$( { git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u )"
      ;;
    *)
      # A typo'd revision must not look like "nothing to see here": without this
      # the reviewers would be told the repo canon is all that applies.
      FILES="$(git diff --name-only "$DIFF" -- 2>/dev/null)" \
        || FILES="$(git show --name-only --format="" "$DIFF" -- 2>/dev/null)" \
        || { echo "unknown revision: $DIFF" >&2; exit 2; }
      FILES="$(printf '%s\n' "$FILES" | sort -u)"
      ;;
  esac
fi

if [ ${#PATH_ARR[@]} -gt 0 ]; then
  if [ -n "$FILES" ]; then
    # Both given: the paths narrow the diff.
    narrowed=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      for p in "${PATH_ARR[@]}"; do
        case "$f" in "$p"|"$p"/*) narrowed="$narrowed$f"$'\n'; break ;; esac
      done
    done <<<"$FILES"
    FILES="$(printf '%s' "$narrowed")"
  else
    # Paths alone: expand tracked directories to the files they hold, and keep
    # the literal paths too — a brand-new file is untracked and would otherwise
    # contribute nothing just because some sibling path happens to be tracked.
    FILES="$( { git ls-files -- "${PATH_ARR[@]}" 2>/dev/null; printf '%s\n' "${PATH_ARR[@]}"; } | sort -u )"
  fi
fi

# Match and traverse on directories, not on the raw file list: a target can be
# thousands of files, and walking each one costs minutes of subprocesses while
# telling us nothing extra — every rule and every nested CLAUDE.md is chosen by
# directory anyway.
DIRS=""
if [ -n "$FILES" ]; then
  # One awk pass emits every path plus each of its parent directories.
  DIRS="$(printf '%s\n' "$FILES" \
          | awk -F/ 'NF{ print; p=""; for (i=1; i<NF; i++) { p = p $i "/"; print substr(p, 1, length(p)-1) } }' \
          | sort -u)"
fi

# Rule names are matched against the SHALLOW part of the tree only. A deep
# asset path like plugins/Nexo/pack/assets/minecraft/... would otherwise drag
# in minecraft.md, and incidental matches like that eat the byte budget before
# the rule that actually applies gets a chance.
SHALLOW="$(printf '%s\n' "$DIRS" | awk -F/ 'NF<=3')"

total=0
emit() { # emit <label> <path>
  label="$1"; path="$2"
  [ -s "$path" ] || return 0
  size=$(wc -c < "$path")
  [ "$total" -lt "$MAX_TOTAL_BYTES" ] || return 0
  printf '\n### %s\n\n' "$label"
  if [ "$size" -gt "$MAX_FILE_BYTES" ]; then
    head -c "$MAX_FILE_BYTES" "$path"
    printf '\n[...truncated, %s bytes total...]\n' "$size"
    total=$(( total + MAX_FILE_BYTES ))
  else
    cat "$path"
    total=$(( total + size ))
  fi
}

# 1. repo canon — always, whatever the target is
for f in CLAUDE.md AGENTS.md; do
  [ -f "$f" ] && emit "$f (project canon)" "$f"
done

# 2. domain rule files, chosen by name against the directories in scope
RULES_DIR=".claude/rules"
if [ -d "$RULES_DIR" ]; then
  rule_count=$(find "$RULES_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
  for rf in "$RULES_DIR"/*.md; do
    [ -f "$rf" ] || continue
    name="$(basename "$rf" .md)"
    if [ "$rule_count" -le 4 ] || [ -z "$DIRS" ]; then
      # Small rule set, or a target with no file list (a whole-repo review):
      # cheaper to send them all than to guess wrong about which one matters.
      emit "$rf" "$rf"
    # Herestring, not a pipe: `grep -q` exits at the first match, the writer
    # gets SIGPIPE, and `set -o pipefail` then reports the whole pipeline as
    # failed — so a rule that DID match would be silently skipped.
    # Whole path components only: a substring match lets api.md claim
    # src/capitalization and eat the byte budget before the real rule emits.
    elif awk -v n="$name" 'BEGIN{ n=tolower(n) }
                           { split(tolower($0), c, "/");
                             for (i in c) if (c[i]==n || index(c[i], n)==1 && length(c[i])<=length(n)+4) { found=1 } }
                           END{ exit !found }' <<<"$SHALLOW"; then
      emit "$rf" "$rf"
    fi
  done
fi

# 3. nested guidance sitting in a directory that is in scope
[ -n "$DIRS" ] || exit 0
printf '%s\n' "$DIRS" | while IFS= read -r d; do
  for g in "$d/CLAUDE.md" "$d/AGENTS.md"; do
    [ -f "$g" ] && printf '%s\n' "$g"
  done
done | sort -u | while IFS= read -r g; do
  [ -n "$g" ] && emit "$g (applies to a directory in scope)" "$g"
done
