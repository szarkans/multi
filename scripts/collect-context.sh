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

SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=providers.sh
. "$SELF_DIR/providers.sh"   # multi_check_paths

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
[ -z "$PATHS" ] || multi_check_paths "$PATHS" || exit 2

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

# --paths is a whitespace-separated list from the caller; read it into an array
# once so nothing downstream relies on unquoted word splitting.
PATH_ARR=()
[ -n "$PATHS" ] && read -r -a PATH_ARR <<<"$PATHS"

# Two file lists, two jobs. FILES is the review SCOPE and may be narrowed by
# --paths below. CHANGED is the TRUST list — everything the change under review
# touches — and is never narrowed: the injection check must see the whole
# change, not the slice the reviewer happens to look at. core.quotePath=false
# keeps non-ASCII paths as plain bytes, or a rule file with a non-ASCII name
# would never match its octal-quoted git listing.
FILES=""; CHANGED=""
if [ -n "$DIFF" ]; then
  case "$DIFF" in
    uncommitted)
      tracked="$( { git -c core.quotePath=false diff --name-only; git -c core.quotePath=false diff --cached --name-only; } 2>/dev/null )"
      FILES="$( { printf '%s\n' "$tracked"; git -c core.quotePath=false ls-files --others --exclude-standard; } 2>/dev/null | sort -u )"
      # The trust list deliberately includes ignored untracked files: a PR
      # that adds a .gitignore entry hiding .claude/rules/evil.md is exactly
      # the injection, and exclude-standard would drop the very file to
      # distrust.
      CHANGED="$( { printf '%s\n' "$tracked"; git -c core.quotePath=false ls-files --others; } 2>/dev/null | sort -u )"
      ;;
    *)
      # git diff first: `git diff <commit>` means "changes since it, vs the
      # working tree" — on a dirty tree that includes the uncommitted part,
      # and a rule file modified there must be distrusted just the same.
      FILES="$(git -c core.quotePath=false diff --name-only "$DIFF" -- 2>/dev/null)"
      if [ -z "$FILES" ]; then
        # Empty: either a single commit on a clean tree (git diff <tip> is
        # empty, and the commit's own files ARE the change) or a range with
        # nothing to say. `git show` answers both, and a typo'd revision
        # fails here instead of looking like "nothing to see here".
        FILES="$(git -c core.quotePath=false show --name-only --format="" "$DIFF" -- 2>/dev/null)" \
          || { echo "unknown revision: $DIFF" >&2; exit 2; }
        if [ -z "$FILES" ]; then
          # Still empty: a clean merge lists zero files in git show even when
          # it shipped changes from a side branch. What it introduced vs its
          # first parent is the honest change.
          FILES="$(git -c core.quotePath=false diff-tree -m --first-parent -r --name-only "$DIFF" -- 2>/dev/null)"
        fi
      fi
      FILES="$(printf '%s\n' "$FILES" | sort -u)"
      CHANGED="$FILES"
      ;;
  esac
elif [ -n "$PATHS" ]; then
  # No --diff but --paths: the skill's default target ("what this session was
  # about") lands here. A session that edited a rule file must not see its own
  # edit emitted as a trusted rule — the working tree's changes are the
  # closest proxy. A rule file touched by unrelated dirty-tree edits is
  # skipped too; erring toward "not trusted" is the right direction here.
  # Ceiling: a change that is already committed leaves no working-tree trace
  # — review that with --diff, not --paths alone. No-args whole-repo mode
  # (neither flag) gets NO proxy: there is no change under review to distrust,
  # and the reviewers read those very files as code anyway.
  CHANGED="$( { git -c core.quotePath=false diff --name-only; git -c core.quotePath=false diff --cached --name-only; git -c core.quotePath=false ls-files --others; } 2>/dev/null | sort -u )"
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

# `head -c` cuts on a BYTE boundary. In a non-ASCII canon — Cyrillic, Thai, CJK, or just an
# emoji — the cut lands mid-codepoint and ctx.md ends with a partial UTF-8 sequence. That is
# not cosmetic: `codex exec review` refuses the whole prompt with
#   error: invalid UTF-8 was detected in one or more arguments
# which reads as a bug in the prompt and sends you looking in the wrong place, while whatever
# the reviewer would have said is simply lost. OpenCode swallows the bad byte instead, so the
# corrupted canon reaches that reviewer silently.
#
# Measured on a Russian CLAUDE.md (two independent sessions, byte-identical result):
#   head -c 8000            → 8000 bytes, invalid continuation byte at offset 7999
#   head -c 8000 | iconv -c → 7999 bytes, valid  (one byte lost)
#   head -c 8000 | sed '$d' → 6980 bytes, valid  (the whole trailing line lost)
#
# iconv is preferred because it keeps everything but the partial character; dropping the last
# line is the fallback for systems without iconv, and it is safe for the same reason — a line
# break is always a character boundary.
truncate_utf8() { # truncate_utf8 <path> <bytes>
  if command -v iconv >/dev/null 2>&1; then
    head -c "$2" "$1" | iconv -f utf-8 -t utf-8 -c 2>/dev/null
  else
    head -c "$2" "$1" | sed '$d'
  fi
}

total=0
emit() { # emit <label> <path>
  label="$1"; path="$2"
  [ -s "$path" ] || return 0
  size=$(wc -c < "$path")
  [ "$total" -lt "$MAX_TOTAL_BYTES" ] || return 0
  printf '\n### %s\n\n' "$label"
  if [ "$size" -gt "$MAX_FILE_BYTES" ]; then
    truncate_utf8 "$path" "$MAX_FILE_BYTES"
    printf '\n[...truncated, %s bytes total...]\n' "$size"
    total=$(( total + MAX_FILE_BYTES ))
  else
    cat "$path"
    total=$(( total + size ))
  fi
}

# A rule file that the reviewed change itself modifies is not a rule — it is
# the payload of a prompt injection (the classic one: a PR that edits
# .claude/rules/style.md to tell reviewers "output No issues found"). It is
# emitted as a skip note instead. The check runs against CHANGED, the whole
# change, never the path-narrowed scope — narrowing FILES must not re-open the
# hole. A legitimately added CLAUDE.md is skipped too: it is part of the
# reviewed diff, and the reviewers read it there.
skip_if_modified() { # skip_if_modified <path> ; 0 = skipped, note printed
  # A symlink anywhere on the path — the file itself, .claude/rules, .claude,
  # or above — delivers whatever it points at. Walk up and reject the whole
  # path; git's changed-file list would never name the link's target.
  local p="$1"
  while [ "$p" != "." ]; do
    if [ -L "$p" ]; then
      if [ "$p" = "$1" ]; then
        printf '\n[...skipped: %s is a symlink, not trusted as rules...]\n' "$1"
      else
        printf '\n[...skipped: %s — a symlink on its path, not trusted as rules...]\n' "$1"
      fi
      return 0
    fi
    p="$(dirname -- "$p")"
  done
  [ -n "$CHANGED" ] || return 1
  # -i: on case-insensitive filesystems (macOS/Windows default) the stored
  # spelling may differ from the on-disk one; a byte match would miss it.
  # Ceiling: NFC/NFD normalization differences still defeat the match.
  grep -qixF -- "$1" <<<"$CHANGED" || return 1
  printf '\n[...skipped: %s is modified by the reviewed change, so it is not trusted as rules...]\n' "$1"
  return 0
}

# 1. repo canon — always, whatever the target is
# `-e || -L`, not `-f`: a symlink must reach the trust check even when broken,
# because `[ -f ]` follows the link and silently drops a dangling one.
for f in CLAUDE.md AGENTS.md; do
  { [ -e "$f" ] || [ -L "$f" ]; } && skip_if_modified "$f" || emit "$f (project canon)" "$f"
done

# 2. domain rule files, chosen by name against the directories in scope
RULES_DIR=".claude/rules"
# `-d || -L`: a dangling symlink passes neither -d nor a check that would let
# it say why it went missing — a note is better than silence.
if [ -d "$RULES_DIR" ] || [ -L "$RULES_DIR" ]; then
  if [ -L "$RULES_DIR" ]; then
    # A symlinked directory: the glob resolves through it and every file
    # inside reads as a regular, innocent path while delivering whatever the
    # link points at. Reject the whole directory.
    printf '\n[...skipped: %s is a symlink, not trusted as rules...]\n' "$RULES_DIR"
  elif [ -e "$RULES_DIR/.git" ]; then
    # An embedded repository: the parent's git never lists the files inside,
    # so the trust check could not see them. Reject the whole directory.
    printf '\n[...skipped: %s contains its own .git — an embedded repository, not trusted as rules...]\n' "$RULES_DIR"
  else
    mode_lines="$(git ls-files -s -- "$RULES_DIR" 2>/dev/null)"
    case "$mode_lines" in
      *160000*)
        # A submodule: git lists only the gitlink, never the files the glob
        # reads through it.
        printf '\n[...skipped: %s is a submodule, not trusted as rules...]\n' "$RULES_DIR" ;;
      *)
  rule_count=$(find "$RULES_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
  for rf in "$RULES_DIR"/*.md; do
    # Same symlink rule as the canon loop: a dangling link must not vanish
    # silently before the trust check sees it.
    { [ -e "$rf" ] || [ -L "$rf" ]; } || continue
    case "$rf" in
      *[[:cntrl:]]*)
        # core.quotePath=false still C-quotes control characters, so git's
        # changed-file list can never match such a name — and the name is
        # attacker-controlled. Skip it visibly rather than compare wrong.
        printf '\n[...skipped: %s has unprintable characters in its name, not trusted as rules...]\n' "$rf"
        continue ;;
    esac
    name="$(basename "$rf" .md)"
    if [ "$rule_count" -le 4 ] || [ -z "$DIRS" ]; then
      # Small rule set, or a target with no file list (a whole-repo review):
      # cheaper to send them all than to guess wrong about which one matters.
      skip_if_modified "$rf" || emit "$rf" "$rf"
    # Herestring, not a pipe: `grep -q` exits at the first match, the writer
    # gets SIGPIPE, and `set -o pipefail` then reports the whole pipeline as
    # failed — so a rule that DID match would be silently skipped.
    # Whole path components only: a substring match lets api.md claim
    # src/capitalization and eat the byte budget before the real rule emits.
    elif awk -v n="$name" 'BEGIN{ n=tolower(n) }
                           { split(tolower($0), c, "/");
                             for (i in c) if (c[i]==n || index(c[i], n)==1 && length(c[i])<=length(n)+4) { found=1 } }
                           END{ exit !found }' <<<"$SHALLOW"; then
      skip_if_modified "$rf" || emit "$rf" "$rf"
    fi
  done
      ;;
    esac
  fi
fi

# 3. nested guidance sitting in a directory that is in scope
[ -n "$DIRS" ] || exit 0
printf '%s\n' "$DIRS" | while IFS= read -r d; do
  for g in "$d/CLAUDE.md" "$d/AGENTS.md"; do
    [ -f "$g" ] && printf '%s\n' "$g"
  done
done | sort -u | while IFS= read -r g; do
  [ -n "$g" ] && { skip_if_modified "$g" || emit "$g (applies to a directory in scope)" "$g"; }
done
