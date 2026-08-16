#!/usr/bin/env bash
# Assemble the project rules that apply to the files under review, so that
# EVERY reviewer — Codex, OpenCode, and the Claude sub-agents — sees the same
# gotchas. Without this the external reviewers know nothing about the project's
# conventions and re-litigate settled decisions.
#
#   collect-context.sh --scope uncommitted           > ctx.md
#   collect-context.sh --scope branch --ref main     > ctx.md
#   collect-context.sh --scope commit --ref <sha>    > ctx.md
#
# Selection rules:
#   - repo-root CLAUDE.md / AGENTS.md always (they are the project canon)
#   - <repo>/.claude/rules/<name>.md when <name> appears in a changed path,
#     or all of them when the repo has few enough to fit
#   - nested CLAUDE.md / AGENTS.md living in a directory that was touched
# Everything is capped so a huge rules tree cannot blow up the reviewer prompts.
set -uo pipefail

SCOPE=uncommitted; REF=""
MAX_TOTAL_BYTES="${MCR_CONTEXT_MAX_BYTES:-24000}"
MAX_FILE_BYTES="${MCR_CONTEXT_MAX_FILE_BYTES:-8000}"

while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

case "$SCOPE" in
  uncommitted) CHANGED="$( { git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard; } | sort -u )" ;;
  branch)      CHANGED="$(git diff --name-only "${REF}...HEAD")" ;;
  commit)      CHANGED="$(git show --name-only --format="" "${REF}")" ;;
  *) echo "unknown scope: $SCOPE" >&2; exit 2 ;;
esac
[ -n "$CHANGED" ] || exit 0

total=0
emit() { # emit <label> <path>
  local label="$1" path="$2" size
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

seen=""
mark() { case " $seen " in *" $1 "*) return 1 ;; *) seen="$seen $1"; return 0 ;; esac; }

# 1. repo canon
for f in CLAUDE.md AGENTS.md; do
  [ -f "$f" ] && mark "$f" && emit "$f (project canon)" "$f"
done

# 2. domain rule files
RULES_DIR=".claude/rules"
if [ -d "$RULES_DIR" ]; then
  rule_count=$(find "$RULES_DIR" -maxdepth 1 -name '*.md' | wc -l)
  for rf in "$RULES_DIR"/*.md; do
    [ -f "$rf" ] || continue
    name="$(basename "$rf" .md)"
    hit=0
    if [ "$rule_count" -le 4 ]; then
      hit=1   # small rule set: cheaper to send it all than to guess wrong
    elif printf '%s\n' "$CHANGED" | grep -qi -- "$name"; then
      hit=1
    fi
    [ "$hit" = 1 ] && mark "$rf" && emit "$rf" "$rf"
  done
fi

# 3. nested guidance next to the changed files
printf '%s\n' "$CHANGED" | while IFS= read -r f; do
  d="$(dirname "$f")"
  while [ "$d" != "." ] && [ "$d" != "/" ]; do
    for g in "$d/CLAUDE.md" "$d/AGENTS.md"; do
      [ -f "$g" ] && printf '%s\n' "$g"
    done
    d="$(dirname "$d")"
  done
done | sort -u | while IFS= read -r g; do
  [ -n "$g" ] && emit "$g (applies to a changed directory)" "$g"
done
