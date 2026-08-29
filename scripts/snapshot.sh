#!/usr/bin/env bash
# Hand the reviewers an ISOLATED copy of the work tree instead of the user's
# live one, and print its path. Everything a reviewer might destroy — a Bash
# sub-agent running `git checkout -- .`, an opencode flipped to bash by a hostile
# repo config — then lands on the copy, and the user's uncommitted work in the
# original is untouched (#14). The copy also drops the repo's own opencode
# config, so a hostile `.opencode/agent/plan.md` cannot re-enable write+bash
# there (#12).
#
#   COPY="$(snapshot.sh --repo "$REPO" --diff uncommitted --dest "$RUN/snapshot")"
#   COPY="$(snapshot.sh --repo "$REPO" --diff "main...HEAD" --dest "$RUN/snapshot")"
#   COPY="$(snapshot.sh --repo "$REPO" --dest "$RUN/snapshot")"   # no diff: read the code
#
# What travels into the copy: tracked files plus untracked-not-ignored ones, WITH
# their uncommitted content — the reviewer must see exactly what the user is
# working on. What stays behind: `.git` (huge, and a worktree/submodule `.git`
# points outside and can execute hooks), everything `.gitignore` hides
# (node_modules, venvs, build output), the repo's opencode config, and any single
# file over the size cap (a reviewer reads code, not a 40 MB asset).
#
# NOT a sandbox. It stops cwd-relative destruction, which is what #14 is in
# practice. A reviewer that reaches for the ORIGINAL by absolute path, or follows
# a symlink out of the copy, is not stopped here — that needs an OS sandbox and
# is out of scope. This raises the floor for #14/#12, it does not seal them.
#
# The change is written INTO the copy as two files the reviewers read directly,
# so nobody needs git in the copy (there is no `.git` there anyway):
#   review.diff      the unified diff under review
#   review.manifest  one `STATUS<TAB>path` line per changed file (A/M/D/R…)
set -uo pipefail

# The copy and its review.diff hold the user's source and may hold an untracked
# secret's neighbourhood; created under /tmp with the usual 022 umask they would
# be world-readable to every local user until the sweep. Tighten to owner-only.
umask 077

SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=providers.sh
. "$SELF_DIR/providers.sh"   # multi_deny_rule: the untracked-secret filter, shared with collect-context

REPO=""; DIFF=""; DEST=""
MAX_FILE_BYTES="${MULTI_SNAPSHOT_MAX_FILE_BYTES:-2097152}"   # 2 MiB
# A non-integer override (a typo, `abc`) would make every `-gt` comparison error
# out and silently disable the cap. Fall back to the default rather than trust it.
case "$MAX_FILE_BYTES" in ''|*[!0-9]*) MAX_FILE_BYTES=2097152 ;; esac
# A value past bash's signed-64-bit range would make `-gt` itself error out and
# disable the cap; anything over ~18 digits is a typo, not a real limit.
[ "${#MAX_FILE_BYTES}" -le 18 ] || MAX_FILE_BYTES=2097152
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need $# "$1"; REPO="$2"; shift 2 ;;
    --diff) need $# "$1"; DIFF="$2"; shift 2 ;;
    --dest) need $# "$1"; DEST="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { echo "--repo is required" >&2; exit 2; }
[ -d "$REPO" ] || { echo "--repo is not a directory: $REPO" >&2; exit 2; }
[ -n "$DEST" ] || { echo "--dest is required" >&2; exit 2; }
# A revision starting with "-" is an option to git, not a revision: `--diff
# --output=/etc/passwd` would make `git diff` write there. Refuse it. (uncommitted
# is the one non-revision keyword we accept.)
case "$DIFF" in -*) echo "--diff must be a revision, not an option: $DIFF" >&2; exit 2 ;; esac

REPO="$(cd -- "$REPO" && pwd)" || { echo "cannot enter --repo: $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "--repo is not a git repo: $REPO" >&2; exit 2; }
ROOT="$(git -C "$REPO" rev-parse --show-toplevel)"

# Create a FRESH unique dir with mktemp instead of wiping --dest in place. This
# script exists to PREVENT data loss and must never cause it: mktemp is atomic and
# never touches an existing path, so `--dest /tmp` cannot be wiped, and an
# accidental second snapshot in the same session (a re-run the caller did not mean
# to make) gets its OWN dir rather than rm -rf'ing a copy a background reviewer is
# still reading. --dest is the base name; the snapshot is a unique sibling of it.
case "$DEST" in ""|/|.|..) echo "--dest is unsafe: $DEST" >&2; exit 2 ;; esac
mkdir -p -- "$(dirname -- "$DEST")" 2>/dev/null || { echo "cannot create parent of --dest: $DEST" >&2; exit 2; }
DEST="$(mktemp -d "${DEST}.XXXXXX" 2>/dev/null)" || { echo "cannot create snapshot dir near --dest: $DEST" >&2; exit 2; }
DEST="$(cd -- "$DEST" && pwd)"
# --dest must live OUTSIDE the repo. Inside it, the `--others` pass would discover
# the snapshot as untracked input and copy it into itself, and the diff writer
# would read review.diff while appending to it. The skills use /tmp; this refuses
# a caller that points --dest into the tree.
case "$DEST/" in "$ROOT"/*) echo "--dest must be outside the repo (it would snapshot itself): $DEST" >&2; rm -rf -- "$DEST"; exit 2 ;; esac

# --- copy the work set: tracked + untracked-not-ignored, uncommitted content ---
# ls-files -z lists raw NUL-delimited paths (no octal quoting), so a non-ASCII or
# spaced name copies correctly. .git is never listed; ignored files are excluded.
skipped="$DEST/.snapshot-skipped.txt"
# ponytail: per-file cp failures are tolerated (|| true) so one unreadable file
# does not abort the whole snapshot; a disk-full / permission storm therefore
# yields a partial copy that still returns 0. The caller's non-empty-$COPY guard
# is the coarse backstop, not a per-file one. Add a completeness check (compare
# copied count to ls-files count) if partial snapshots ever bite in practice.
# multi_deny_rule does two jobs: it names secrets (env-file, ssh-key, …) AND it
# rejects names that are unsafe to paste into a shell command (unsafe-name,
# unquotable-name — spaces, metacharacters). Only the first job matters here:
# snapshot never interpolates a name into a shell command (cp/git run with quoted,
# NUL-delimited, `--`-terminated arguments), so a legitimate `src/new component.ts`
# must NOT be mistaken for a secret and dropped from the review. Withhold only on a
# real secret category; SECRET_RULE carries which one for the note.
SECRET_RULE=""
snap_is_secret() { # snap_is_secret <path> -> 0 if a real secret to withhold
  local r; r="$(multi_deny_rule "$1")"
  case "$r" in
    ''|unsafe-name|unquotable-name) return 1 ;;
    *) SECRET_RULE="$r"; return 0 ;;
  esac
}
copy_one() { # copy_one <path>
  local f="$1" src="$ROOT/$1" dst="$DEST/$1" sz
  # Strip the reviewed repo's own opencode config from the copy (#12), any depth.
  case "$f" in .opencode/*|opencode.json|*/.opencode/*|*/opencode.json) return ;; esac
  # A control character (newline/tab) in a name is attacker-controlled; the diff
  # loop already refuses to list such a file, so do not copy it either, or the
  # manifest's "not copied" note becomes a lie (the file would be in the tree).
  case "$f" in *[[:cntrl:]]*) printf '%s (unprintable name, not copied)\n' "$f" >> "$skipped"; return ;; esac
  # Skip symlinks entirely, with a note: a link is either intra-repo (its target
  # is copied on its own if tracked) or an escape hatch — `key -> ~/.ssh/id_rsa`
  # would hand a secret to the cloud reviewers, and a link named `review.diff` or
  # `.opencode` would defeat the artifact write and the config strip.
  if [ -L "$src" ]; then printf '%s (symlink, not copied)\n' "$f" >> "$skipped"; return; fi
  # A submodule/gitlink is listed by ls-files but is a directory on disk — a
  # separate repo, not ours to copy. Say so, or a reviewer of a repo with
  # submodules gets a silently missing subtree. Distinct from a genuinely deleted
  # tracked file (below), not on disk at all, which is correctly a no-op.
  if [ -d "$src" ]; then printf '%s (submodule/gitlink, not copied)\n' "$f" >> "$skipped"; return; fi
  [ -f "$src" ] || return   # deleted-but-tracked: listed, not on disk
  # The secret filter runs on EVERY file, tracked or not. `--diff uncommitted`
  # ships uncommitted edits, and a live credential typed into an already-tracked
  # `.env`/keyfile is exactly as sensitive as one in an untracked file — "the user
  # committed it" is true of the old content, not of the edit under review.
  if snap_is_secret "$f"; then printf '%s (withheld: %s — secret, not sent to reviewers)\n' "$f" "$SECRET_RULE" >> "$skipped"; return; fi
  sz=$(wc -c < "$src" 2>/dev/null); sz="${sz//[!0-9]/}"; [ -n "$sz" ] || sz=0
  if [ "$sz" -gt "$MAX_FILE_BYTES" ]; then printf '%s\n' "$f" >> "$skipped"; return; fi
  mkdir -p -- "$(dirname -- "$dst")" 2>/dev/null || return
  cp -p -- "$src" "$dst" 2>/dev/null || cp -- "$src" "$dst" 2>/dev/null || true
}
git -C "$ROOT" ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do copy_one "$f"; done

# Backstop the opencode-config strip. The copy loop skips it by path, but only
# case-sensitively and only for the exact names — a case-variant (.OpenCode on a
# case-insensitive macOS/Windows FS), an .opencode.jsonc, or an
# opencode.config.ts still loads as valid opencode config. Purge them by name,
# case-insensitively, at any depth, whatever slipped through.
find "$DEST" \( -iname '.opencode' -o -iname 'opencode.json' -o -iname 'opencode.jsonc' \
                -o -iname 'opencode.config.*' \) -exec rm -rf -- {} + 2>/dev/null || true

# --- write the change as files the reviewers read directly ------------------
[ -n "$DIFF" ] || { printf '%s' "$DEST"; exit 0; }

# ponytail: review.manifest is line-oriented "STATUS<TAB>path", but a rename from
# `git diff --name-status` is 3-column (R100<TAB>old<TAB>new) and a filename with
# an embedded newline splits its line. Reviewers read review.diff for the real
# change; the manifest is an index. Switch to a -z/NUL format if a parser ever
# depends on it.
DIFFOUT="$DEST/review.diff"
MANOUT="$DEST/review.manifest"
# Remove anything the copy may have left at these exact paths before writing — a
# repo that tracks its own review.diff must not have our write land on a copied
# file (a symlink is already skipped in the copy, closing the out-of-tree case).
rm -f -- "$DIFFOUT" "$MANOUT" "$DIFFOUT.try"
: > "$DIFFOUT"; : > "$MANOUT"
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"   # git's canonical empty tree

# The tracked diff is a SINGLE `git diff` over all changed files, so a per-file
# skip cannot happen inside it the way it does in the copy and the untracked loop.
# Instead compute which changed files to hold out and pass them as `:(exclude)`
# pathspecs. Three reasons a tracked file is held out of review.diff, all of which
# the copy already enforces but the diff did not: it is opencode config (#12 — a
# tracked plan.md edit would otherwise still reach the reviewer), it is a secret
# (an uncommitted credential in a tracked `.env` is exactly what --diff
# uncommitted sends), or it is over the size cap (a regenerated lockfile would
# bloat the artifact the reviewers actually read). checksize=1 uses the on-disk
# working-tree size, so it only applies to the uncommitted diff.
EXARGS=()
build_excludes() { # build_excludes <rev> <checksize:0|1>
  EXARGS=(); local f rev="$1" checksize="$2" sz
  while IFS= read -r -d '' f; do
    case "$f" in
      .opencode/*|opencode.json|*/.opencode/*|*/opencode.json)
        EXARGS+=(":(exclude,literal)$f"); printf '%s (opencode config, held out of the diff)\n' "$f" >> "$skipped"; continue ;;
    esac
    if snap_is_secret "$f"; then
      EXARGS+=(":(exclude,literal)$f"); printf '%s (withheld: %s — secret, not in diff)\n' "$f" "$SECRET_RULE" >> "$skipped"; continue
    fi
    if [ "$checksize" = 1 ] && [ -f "$ROOT/$f" ]; then
      sz=$(wc -c < "$ROOT/$f" 2>/dev/null); sz="${sz//[!0-9]/}"; [ -n "$sz" ] || sz=0
      [ "$sz" -gt "$MAX_FILE_BYTES" ] && { EXARGS+=(":(exclude,literal)$f"); printf '%s (over %s bytes, held out of the diff)\n' "$f" "$MAX_FILE_BYTES" >> "$skipped"; }
    fi
  done < <(git -C "$ROOT" -c core.quotePath=false diff "$rev" --name-only -z 2>/dev/null)
}

if [ "$DIFF" = "uncommitted" ]; then
  # Tracked changes: working tree vs HEAD covers staged AND unstaged in one pass.
  # No commit yet? Diff against the empty tree so everything reads as added.
  base="$EMPTY_TREE"
  git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1 && base="HEAD"
  build_excludes "$base" 1
  git -C "$ROOT" -c core.quotePath=false diff "$base" -- . ${EXARGS[@]+"${EXARGS[@]}"} >> "$DIFFOUT" 2>/dev/null || true
  git -C "$ROOT" -c core.quotePath=false diff "$base" --name-status -- . ${EXARGS[@]+"${EXARGS[@]}"} >> "$MANOUT" 2>/dev/null || true
  # Untracked-not-ignored files are additions: git diff vs HEAD never shows them.
  git -C "$ROOT" ls-files -z --others --exclude-standard \
  | while IFS= read -r -d '' f; do
      case "$f" in .opencode/*|opencode.json|*/.opencode/*|*/opencode.json) continue ;; esac
      # A control character (newline, tab) in a name is attacker-controlled and
      # would forge a second manifest line (`A\tevil<NL>D\tfake` reads as two
      # rows). git C-quotes such names in the diff, but our printf does not — skip
      # it, with a note, rather than emit a splittable row.
      case "$f" in *[[:cntrl:]]*) printf '%s (unprintable name, not listed)\n' "$f" >> "$skipped"; continue ;; esac
      src="$ROOT/$f"
      # Skip symlinks here too: `git diff --no-index` lstats the link and writes a
      # mode-120000 entry whose body is the target PATH (e.g. ~/.ssh/id_rsa) into
      # review.diff, which ships to the cloud reviewers. The copy loop already
      # drops the link itself; this keeps its target out of the diff as well.
      [ -L "$src" ] && continue
      [ -f "$src" ] || continue
      # Same secret filter as the copy: without it a `.env`'s CONTENT would reach
      # review.diff (and the cloud reviewers) via --no-index below.
      snap_is_secret "$f" && continue
      sz=$(wc -c < "$src" 2>/dev/null); sz="${sz//[!0-9]/}"; [ -n "$sz" ] || sz=0
      if [ "$sz" -gt "$MAX_FILE_BYTES" ]; then
        # Over the cap: it is not in the copy and not in the diff. Say so in the
        # manifest, or a big new file is simply invisible to the reviewer.
        printf 'A\t%s\t(skipped: over %s bytes, not in copy or diff)\n' "$f" "$MAX_FILE_BYTES" >> "$MANOUT"
        continue
      fi
      # --no-index against /dev/null renders the file as a brand-new addition.
      # It exits 1 when they differ (they always do) — that is success here.
      git -C "$ROOT" -c core.quotePath=false diff --no-index -- /dev/null "$f" >> "$DIFFOUT" 2>/dev/null || true
      printf 'A\t%s\n' "$f" >> "$MANOUT"
    done
else
  # ponytail: two known ceilings here, both shared with collect-context.sh, both
  # low-impact because the orchestrators steer to ranges (main...HEAD). (1) For a
  # bare single commit on a dirty/descendant tree `git diff <sha>` yields
  # <sha>..worktree, not the commit's own patch — pass a range to review a commit
  # precisely. (2) A clean MERGE commit shows empty here; collect-context recovers
  # it with `diff-tree --no-commit-id -m --first-parent`, this does not. Add that
  # fallback if merge-commit reviews ever matter.
  # A revision or range. Gate on whether git can RESOLVE it, not on whether the
  # diff is empty — a valid range with no changes (a branch not ahead of main) is
  # empty AND legitimate, and must not be mistaken for a typo. `git diff` exits
  # non-zero only when the revision itself does not resolve.
  # Hold opencode config and secrets out of this diff too (checksize=0: range
  # files carry the tip's content, not the on-disk one). On an invalid rev the
  # inner name-only is empty, EXARGS stays empty, and the resolve check below
  # still fails correctly.
  build_excludes "$DIFF" 0
  if git -C "$ROOT" -c core.quotePath=false diff "$DIFF" -- . ${EXARGS[@]+"${EXARGS[@]}"} > "$DIFFOUT.try" 2>/dev/null; then
    if [ -s "$DIFFOUT.try" ]; then
      mv "$DIFFOUT.try" "$DIFFOUT"
      git -C "$ROOT" -c core.quotePath=false diff "$DIFF" --name-status -- . ${EXARGS[@]+"${EXARGS[@]}"} >> "$MANOUT" 2>/dev/null || true
    else
      # Valid revision, empty diff. Two sub-cases: a single commit on a clean tree
      # (its patch is via `git show`), or a range that genuinely changed nothing.
      rm -f "$DIFFOUT.try"
      if git -C "$ROOT" -c core.quotePath=false show "$DIFF" -- . ${EXARGS[@]+"${EXARGS[@]}"} > "$DIFFOUT" 2>/dev/null && [ -s "$DIFFOUT" ]; then
        git -C "$ROOT" -c core.quotePath=false show --name-status --format="" "$DIFF" -- . ${EXARGS[@]+"${EXARGS[@]}"} >> "$MANOUT" 2>/dev/null || true
      else
        # Genuinely no changes on a valid revision — leave review.diff empty and
        # proceed. An empty diff is an honest "nothing to review", not a failure.
        : > "$DIFFOUT"
      fi
    fi
  else
    # git could not resolve the revision at all — a typo. Fail loudly with no path
    # on stdout, so the caller's `COPY="$(snapshot.sh …)"` comes back empty and the
    # review aborts instead of running against a phantom clean change.
    rm -f "$DIFFOUT.try"
    echo "snapshot: unknown revision: $DIFF" >&2
    exit 2
  fi
fi

# Tell the reviewers, in the manifest, about anything left out of the copy (too
# large, or a symlink). Its change still shows in review.diff, but "the file is in
# the tree" would otherwise be a silent lie — the same visibility the untracked
# over-cap case gets inline above, now for tracked files and symlinks too.
if [ -s "$skipped" ]; then
  { echo ""
    echo "# held out of this snapshot AND out of review.diff (a secret, symlink, submodule, opencode config, an over-cap file, or an unprintable name). Each line says which:"
    sed 's/^/#   /' "$skipped"
  } >> "$MANOUT" 2>/dev/null || true
fi

printf '%s' "$DEST"
