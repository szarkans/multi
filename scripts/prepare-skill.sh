#!/usr/bin/env bash
# Make the one copy of a skill that /multi:skill hands to every participant
# (docs/adr/0003). Launches nothing -- ask.sh stays the only transport; this is
# file work, the same kind as snapshot.sh.
#
#   prepare-skill.sh --skill <skill dir | SKILL.md> --into <run dir> [--args "<text>"]
#   prepare-skill.sh --verify <copy>
#
# Prints:
#   skill-dir: <copy>        pass to ask.sh --read-dir, name it in the question
#   withheld: <file> (<why>) left out of the copy: a secret-looking name, a
#                            symlink, a .git -- the host says so out loud
#   host-command: <command>  a !`command` from the skill's own text, for the
#                            host to run and paste in over the marker
# --verify exits 1, naming them, while any of those markers is still in the
# copy: a participant must never receive one.
#
# Exit: 0 ok, 1 failed, 2 usage / not a skill, 3 the skill is multi's own.
set -uo pipefail
# The copy holds the skill and the user's arguments under /tmp/multi; other
# local users have no business reading either.
umask 077
SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=providers.sh
. "$SELF_DIR/providers.sh"

SKILL=""; INTO=""; ARGS=""; VERIFY=""
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --skill)  need $# "$1"; SKILL="$2"; shift 2 ;;
    --into)   need $# "$1"; INTO="$2"; shift 2 ;;
    --args)   need $# "$1"; ARGS="$2"; shift 2 ;;
    --verify) need $# "$1"; VERIFY="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
PY="$(multi_python)" || { echo "prepare-skill.sh: no working python3" >&2; exit 1; }

if [ -n "$VERIFY" ]; then
  VERIFY="${VERIFY%/}"
  [ -f "$VERIFY/SKILL.md" ] && [ -f "$VERIFY.commands.json" ] \
    || { echo "not a prepared copy: $VERIFY" >&2; exit 2; }
  "$PY" -c 'import json, sys
body = open(sys.argv[1], encoding="utf-8").read()
left = [m for m in json.load(open(sys.argv[2], encoding="utf-8")) if m in body]
for m in left:
    print("still in the copy: " + m, file=sys.stderr)
sys.exit(1 if left else 0)' "$VERIFY/SKILL.md" "$VERIFY.commands.json"
  exit $?
fi

[ -n "$SKILL" ] && [ -n "$INTO" ] || { echo "usage: prepare-skill.sh --skill <dir|SKILL.md> --into <dir> [--args <text>] | --verify <copy>" >&2; exit 2; }
case "$SKILL" in */SKILL.md|SKILL.md) SKILL="$(dirname -- "$SKILL")" ;; esac
[ -f "$SKILL/SKILL.md" ] || { echo "not a skill, no SKILL.md in: $SKILL" >&2; exit 2; }
SRC="$(cd "$SKILL" && pwd -P)"

# Multi inside multi. The skill body says so too; this catches a host that
# skipped that paragraph or reached the skill by another path.
OWN="$(cd "$SELF_DIR/../skills" && pwd -P)"
case "$SRC/" in "$OWN"/*) echo "multi inside multi: $SRC is one of multi's own skills" >&2; exit 3 ;; esac

# List first, copy second, and a listing that failed is a failed run: an
# unreadable folder must not turn into a quietly smaller copy. NUL-separated:
# with newlines, a folder named "a<newline>/home/me/x" split into a second
# entry -- an absolute path -- that was copied from the real filesystem.
# .git is pruned (and reported): a skill that is its own repository would ship
# its history and a remote URL that may carry a token.
LIST="$(mktemp)" || exit 1
trap 'rm -f "$LIST"' EXIT
find "$SRC" -name .git -prune -print0 -o \( -type f -o -type l \) -print0 > "$LIST" \
  || { echo "could not list every file in $SRC -- not making a partial copy" >&2; exit 1; }

# A copy of its own every run: a second /multi:skill of the same skill must not
# rewrite files the first one's participants are still reading, and a skill
# prepared from an earlier copy never has its source deleted.
mkdir -p "$INTO/skill" || exit 1
DEST="$(mktemp -d "$(cd "$INTO/skill" && pwd -P)/${SRC##*/}.XXXXXX")" || exit 1

# Symlinks stay behind, as in snapshot.sh: the secret rules judge a NAME, and a
# link's name says nothing about its target (notes.md -> ~/.ssh/id_rsa). The
# rest goes through the same rules as a review (multi_deny_rule).
# Over-withholding is the safe direction: a name the rules cannot vouch for
# (a space or a newline in it) stays behind and is reported, not sent.
WITHHELD=""
nl='
'
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  shown="${rel//"$nl"/?}"
  if [ "${rel##*/}" = .git ]; then why="git-dir"
  elif [ -L "$f" ]; then why="symlink"
  else why="$(multi_deny_rule "$rel")"
  fi
  if [ -n "$why" ]; then
    WITHHELD="${WITHHELD}withheld: $shown ($why)$nl"
    continue
  fi
  mkdir -p "$DEST/$(dirname -- "$rel")" && cp "$f" "$DEST/$rel" \
    || { echo "could not copy $f" >&2; exit 1; }
done < "$LIST"

# What Claude Code does to a skill before its model sees it; no other harness
# does (agentskills.io has no substitutions). One regex pass, so arguments that
# themselves contain a placeholder stay literal. A body without a plain
# $ARGUMENTS gets them appended, as Claude Code does.
# !`command` markers are taken from the skill's OWN text, before the arguments
# go in -- a marker typed inside the arguments is the user's words, not a
# command -- and filled in the same way, because the host runs what Claude
# Code would have run. They are recorded beside the copy for --verify.
# ponytail: only $ARGUMENTS and ${CLAUDE_SKILL_DIR}; $0/$1, $ARGUMENTS[N] and
# named arguments stay as written -- add them when a skill needs them.
"$PY" -c 'import json, re, sys
path, skill_dir, args, cmds_out = sys.argv[1:5]
body = open(path, encoding="utf-8").read()
pat = re.compile(r"\$ARGUMENTS(?!\[)|\$\{CLAUDE_SKILL_DIR\}")
fill = lambda s: pat.sub(lambda m: args if m.group(0) == "$ARGUMENTS" else skill_dir, s)
markers = [fill(m) for m in re.findall(r"!`[^`\n]+`", body)]
had_args = re.search(r"\$ARGUMENTS(?!\[)", body) is not None
body = fill(body)
if args and not had_args:
    body = body.rstrip("\n") + "\n\nARGUMENTS: " + args + "\n"
open(path, "w", encoding="utf-8").write(body)
json.dump(markers, open(cmds_out, "w", encoding="utf-8"))
for m in markers:
    print("host-command: " + m[2:-1].replace("\n", " "))' "$DEST/SKILL.md" "$DEST" "$ARGS" "$DEST.commands.json" > "$DEST.commands.txt" \
  || { echo "could not fill in $DEST/SKILL.md" >&2; exit 1; }

echo "skill-dir: $DEST"
printf '%s' "$WITHHELD"
cat "$DEST.commands.txt"
rm -f "$DEST.commands.txt"
