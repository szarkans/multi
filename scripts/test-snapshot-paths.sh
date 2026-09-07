#!/usr/bin/env bash
# The copy must hold the code under review. `git ls-files --exclude-standard`
# honours .git/info/exclude, so a `docs/` line there silently dropped the very
# folder under review and every reviewer agreed there was nothing to review
# (#29). With --paths, a missing path is a hard stop that names the ignore rule.
#
#   bash scripts/test-snapshot-paths.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MULTI_HOME="$TMP/h"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
snap() { bash "$TREE/scripts/snapshot.sh" --repo "$TMP/repo" --dest "$TMP/snap" "$@"; }

git init -q "$TMP/repo"; cd "$TMP/repo"
mkdir -p docs/item-map src
echo x > src/a.py; echo y > docs/item-map/b.md
git add src; git -c user.email=t@t -c user.name=t commit -qm init
echo 'docs/' >> .git/info/exclude

echo "== a path hidden by .git/info/exclude =="
C="$(snap --paths "docs/item-map src" 2>"$TMP/err")"; rc=$?
say "exit 2, no path on stdout" "$rc:$C" "2:"
say "names the rule file and line, not the pattern" "$(grep -c 'docs/item-map is not in the copy: ignored via .git/info/exclude:[0-9]*$' "$TMP/err")" "1"
say "the copy's skipped list says so too" "$(cat "$TMP"/snap.*/.snapshot-skipped.txt | grep -c 'docs/item-map (requested via --paths, NOT in the copy: ignored via')" "1"
rm -rf "$TMP"/snap.*

echo "== the same path once it is not ignored =="
: > .git/info/exclude
C="$(snap --paths "docs/item-map src" 2>"$TMP/err")"; rc=$?
say "exit 0 with a path" "$rc:$([ -n "$C" ] && echo path)" "0:path"
say "the folder is in the copy" "$([ -f "$C/docs/item-map/b.md" ] && echo yes || echo no)" "yes"
rm -rf "$TMP"/snap.*

echo "== shapes of a path =="
C="$(snap --paths "./src src/ src/a.py" 2>/dev/null)"; say "./x, x/ and a file all resolve" "$?" "0"; rm -rf "$TMP"/snap.*
C="$(snap --paths 'src/*.py docs/**' 2>/dev/null)"; say "a glob is not checked (cannot be, cheaply)" "$?" "0"; rm -rf "$TMP"/snap.*
C="$(snap --paths "src nope/x.py" 2>"$TMP/err")"; rc=$?
say "a path that does not exist at all is exit 2" "$rc" "2"
say "and says so" "$(grep -c 'nope/x.py is not in the copy: does not exist' "$TMP/err")" "1"
rm -rf "$TMP"/snap.*
C="$(snap --paths 'src; id' 2>/dev/null)"; say "metacharacters are refused like everywhere else" "$?" "2"

echo "== a secret named in --paths is withheld, and the stop says where to look =="
echo 'k=v' > .env; git add -f .env >/dev/null 2>&1
C="$(snap --paths ".env" 2>"$TMP/err")"; rc=$?
say "exit 2" "$rc" "2"
say "points at .snapshot-skipped.txt" "$(grep -c 'see .snapshot-skipped.txt' "$TMP/err")" "1"

echo "== a harness rule file is stripped on purpose, not missing =="
echo r > AGENTS.md; git add AGENTS.md
C="$(snap --paths "AGENTS.md src" 2>"$TMP/err")"; say "AGENTS.md in --paths does not fail the snapshot" "$?" "0"
say "and the skipped list says why" "$(grep -c 'AGENTS.md (requested via --paths; a harness rule file' "$C/.snapshot-skipped.txt")" "1"
rm -rf "$TMP"/snap.*

echo "== a deletion under review is not a missing path =="
git -c user.email=t@t -c user.name=t commit -qm agents; git rm -q src/a.py
C="$(snap --diff uncommitted --paths "src/a.py" 2>"$TMP/err")"; say "deleted file named in --paths, with --diff: ok" "$?" "0"
say "review.diff carries the deletion" "$(grep -c '^deleted file' "$C/review.diff")" "1"
rm -rf "$TMP"/snap.*
C="$(snap --paths "src/a.py" 2>"$TMP/err")"; say "the same without --diff is a missing path" "$?" "2"
git checkout -q -- src/a.py 2>/dev/null || git reset -q --hard

echo "== a whole directory the change deleted is not a missing path =="
mkdir -p gone; echo z > gone/z.py; git add gone; git -c user.email=t@t -c user.name=t commit -qm gone; git rm -rq gone
C="$(snap --diff uncommitted --paths "gone" 2>"$TMP/err")"; say "deleted directory named in --paths, with --diff: ok" "$?" "0"
rm -rf "$TMP"/snap.*; git reset -q --hard

echo "== opencode config is a stop, not a note =="
echo '{}' > opencode.json; git add opencode.json
C="$(snap --paths "opencode.json" 2>"$TMP/err")"; say "exit 2" "$?" "2"
say "says it is withheld on purpose" "$(grep -c 'withheld from reviewers on purpose' "$TMP/err")" "1"
git rm -q --cached opencode.json; rm -f opencode.json; rm -rf "$TMP"/snap.*

echo "== a rule-file NAME that exists nowhere is a typo, not a note =="
C="$(snap --paths "GEMINI.md" 2>"$TMP/err")"; say "exit 2" "$?" "2"
say "says it does not exist" "$(grep -c 'GEMINI.md is not in the copy: does not exist' "$TMP/err")" "1"
rm -rf "$TMP"/snap.*

echo "== a case variant is stripped like the purge strips it =="
echo r > agents.md; git add agents.md
C="$(snap --paths "agents.md src" 2>"$TMP/err")"; say "agents.md in --paths does not fail the snapshot" "$?" "0"
git rm -q --cached agents.md; rm -f agents.md; rm -rf "$TMP"/snap.*

echo "== a name the config purge removes is caught =="
echo '{}' > .mcp.json; git add .mcp.json
C="$(snap --paths ".mcp.json" 2>"$TMP/err")"; say "presence is checked against the final tree" "$?" "0"
say "stripped on purpose, says the list" "$(grep -c '.mcp.json (requested via --paths; a harness rule file' "$C/.snapshot-skipped.txt")" "1"
git rm -q --cached .mcp.json; rm -f .mcp.json; rm -rf "$TMP"/snap.*

echo "== no --paths: unchanged, ignored files simply absent =="
echo 'docs/' >> .git/info/exclude
C="$(snap 2>/dev/null)"; say "exit 0" "$?" "0"
say "docs not in the copy" "$([ -e "$C/docs" ] && echo yes || echo no)" "no"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
