#!/usr/bin/env bash
# Checks prepare-skill.sh: the one copy of a skill that /multi:skill hands to
# every participant. Pure file work -- no backends, no network.
#
#   bash scripts/test-prepare-skill.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PREP="$HERE/prepare-skill.sh"

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
tree_sum() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; cksum < "$f"; done); }

SRC="$TMP/src/my-skill"
mkdir -p "$SRC/references"
cat > "$SRC/SKILL.md" <<'EOF'
---
name: my-skill
description: test
---
Read references/notes.md.
EOF
echo "NOTE-WORD" > "$SRC/references/notes.md"
before="$(tree_sum "$SRC")"

# --- the copy: whole folder, source untouched -----------------------------
out="$("$PREP" --skill "$SRC" --into "$TMP/run" 2>"$TMP/err")"; rc=$?
dest="$(sed -n 's/^skill-dir: //p' <<<"$out")"
[ $rc -eq 0 ] && ok "exit 0" || bad "exit $rc: $(head -2 "$TMP/err")"
[ -n "$dest" ] && [ "${dest#"$TMP/run/"}" != "$dest" ] && ok "copy lives under --into ($dest)" || bad "no skill-dir under --into: $out"
[ -f "$dest/SKILL.md" ] && grep -qx NOTE-WORD "$dest/references/notes.md" 2>/dev/null \
  && ok "SKILL.md and references/ copied" || bad "copy incomplete: $(ls -R "$dest" 2>&1 | tr '\n' ' ')"
[ "$(tree_sum "$SRC")" = "$before" ] && ok "source folder untouched" || bad "source folder changed"

# --skill may name the SKILL.md itself.
out2="$("$PREP" --skill "$SRC/SKILL.md" --into "$TMP/run2" 2>/dev/null)"
[ -f "$(sed -n 's/^skill-dir: //p' <<<"$out2")/references/notes.md" ] && ok "--skill accepts the SKILL.md path" || bad "--skill <SKILL.md> failed: $out2"

# A folder without SKILL.md is not a skill.
mkdir -p "$TMP/notaskill"
"$PREP" --skill "$TMP/notaskill" --into "$TMP/run3" >/dev/null 2>"$TMP/err3"; rc=$?
[ $rc -eq 2 ] && grep -q SKILL.md "$TMP/err3" && ok "no SKILL.md -> exit 2" || bad "no SKILL.md: rc=$rc $(head -1 "$TMP/err3")"

# Every run gets a copy of its own: a second /multi:skill of the same skill in
# the same session must not rewrite files the first one's participants are
# still reading, nor inherit its answers.
[ -n "$dest" ] && echo first > "$dest/references/mine.md"
d2="$("$PREP" --skill "$SRC" --into "$TMP/run" 2>/dev/null | sed -n 's/^skill-dir: //p')"
[ -n "$d2" ] && [ "$d2" != "$dest" ] && [ -f "$d2/SKILL.md" ] && [ ! -e "$d2/references/mine.md" ] && [ -f "$dest/references/mine.md" ] \
  && ok "rerun gets a fresh copy, the first one untouched" || bad "rerun reused or rewrote the first copy ($dest vs $d2)"

# Preparing a prepared copy again must never delete it (the source).
"$PREP" --skill "$dest" --into "$TMP/run" >/dev/null 2>&1
[ -f "$dest/SKILL.md" ] && ok "a copy used as --skill survives" || bad "preparing from a copy deleted it"

# --- substitutions: what only Claude Code would have filled in --------------
# The arguments come from the user's words; every character that breaks a sed
# replacement or a shell must land literally.
NASTY='a "b" $HOME /x\y & '\''z'\'' \1 $ARGUMENTS'
SUB="$TMP/src/sub-skill"; mkdir -p "$SUB"
cat > "$SUB/SKILL.md" <<'EOF'
---
name: sub-skill
description: test
---
Target: $ARGUMENTS
Docs: ${CLAUDE_SKILL_DIR}/references
EOF
out="$("$PREP" --skill "$SUB" --into "$TMP/run4" --args "$NASTY" 2>/dev/null)"
d4="$(sed -n 's/^skill-dir: //p' <<<"$out")"
grep -qxF "Target: $NASTY" "$d4/SKILL.md" 2>/dev/null && ok "\$ARGUMENTS replaced literally" || bad "\$ARGUMENTS: $(grep Target "$d4/SKILL.md" 2>&1)"
grep -qxF "Docs: $d4/references" "$d4/SKILL.md" 2>/dev/null && ok "\${CLAUDE_SKILL_DIR} -> the copy" || bad "CLAUDE_SKILL_DIR: $(grep Docs "$d4/SKILL.md" 2>&1)"
grep -qF 'Target: $ARGUMENTS' "$SUB/SKILL.md" && ok "source SKILL.md keeps its placeholders" || bad "source SKILL.md was rewritten"

# No $ARGUMENTS in the body: Claude Code appends them, so must we.
d5="$("$PREP" --skill "$SRC" --into "$TMP/run5" --args "src/app.py" 2>/dev/null | sed -n 's/^skill-dir: //p')"
grep -qxF "ARGUMENTS: src/app.py" "$d5/SKILL.md" && ok "arguments appended when the body has no \$ARGUMENTS" || bad "arguments not appended"
# ...and nothing is appended when there are no arguments.
grep -q '^ARGUMENTS:' "$dest/SKILL.md" && bad "ARGUMENTS line added without --args" || ok "no --args, no ARGUMENTS line"

# --- !`command`: listed for the host, never run here ------------------------
# The host runs them through its own shell tool, so the user's permission
# prompt applies (ADR 0003). This script must not execute a single one.
BANG="$TMP/src/bang-skill"; mkdir -p "$BANG"
cat > "$BANG/SKILL.md" <<EOF
---
name: bang-skill
description: test
---
!\`touch $TMP/MARKER\`

Status: !\`git status --short\` and more text
EOF
out="$("$PREP" --skill "$BANG" --into "$TMP/run6" 2>/dev/null)"
[ ! -e "$TMP/MARKER" ] && ok "!\`command\` not executed" || bad "prepare-skill.sh ran a !\`command\`"
want="host-command: touch $TMP/MARKER
host-command: git status --short"
[ "$(grep '^host-command: ' <<<"$out")" = "$want" ] && ok "both !\`commands\` listed for the host, in order" || bad "host-command lines: $(grep '^host-command' <<<"$out" | tr '\n' '|')"

# --- secret files never reach the copy -------------------------------------
SEC="$TMP/src/sec-skill"; mkdir -p "$SEC/references"
printf -- '---\nname: sec-skill\ndescription: t\n---\nx\n' > "$SEC/SKILL.md"
echo "API_KEY=sk-live" > "$SEC/.env"
echo "KEY" > "$SEC/references/id_rsa"
echo "ok" > "$SEC/references/guide.md"
out="$("$PREP" --skill "$SEC" --into "$TMP/run7" 2>/dev/null)"
d7="$(sed -n 's/^skill-dir: //p' <<<"$out")"
[ -n "$d7" ] && [ ! -e "$d7/.env" ] && [ ! -e "$d7/references/id_rsa" ] && [ -f "$d7/references/guide.md" ] \
  && ok "secret files left out, the rest copied" || bad "secret filter: $(cd "$d7" 2>/dev/null && find . -type f | tr '\n' ' ')"
grep -qx 'withheld: .env (env-file)' <<<"$out" && grep -qx 'withheld: references/id_rsa (ssh-key)' <<<"$out" \
  && ok "withheld files named with their rule" || bad "withheld lines: $(grep '^withheld' <<<"$out" | tr '\n' '|')"

# --- links and .git never travel (same rule as snapshot.sh) ----------------
# A link's NAME is all the secret filter sees; what it would copy is the
# target. notes.md -> ~/.ssh/id_rsa passed the filter and shipped the key.
LNK="$TMP/src/link-skill"; mkdir -p "$LNK/references" "$LNK/.git" "$TMP/outside/docs"
printf -- '---\nname: link-skill\ndescription: t\n---\nx\n' > "$LNK/SKILL.md"
echo "REAL-OUTSIDE-SECRET" > "$TMP/outside/id_rsa"
echo "outside doc" > "$TMP/outside/docs/a.md"
ln -s "$TMP/outside/id_rsa" "$LNK/references/notes.md"
ln -s "$TMP/outside/docs" "$LNK/references/shared"
echo "[remote] url = https://user:TOKEN@example.test/r.git" > "$LNK/.git/config"
out="$("$PREP" --skill "$LNK" --into "$TMP/run8" 2>/dev/null)"
d8="$(sed -n 's/^skill-dir: //p' <<<"$out")"
[ -n "$d8" ] && ! grep -rqs REAL-OUTSIDE-SECRET "$d8" && [ ! -e "$d8/references/notes.md" ] \
  && ok "file link not followed into the copy" || bad "a linked file reached the copy"
[ -n "$d8" ] && [ ! -e "$d8/references/shared" ] && ok "directory link not followed" || bad "a linked directory reached the copy"
grep -qx 'withheld: references/notes.md (symlink)' <<<"$out" && grep -qx 'withheld: references/shared (symlink)' <<<"$out" \
  && ok "both links named as withheld" || bad "links not reported: $(grep '^withheld' <<<"$out" | tr '\n' '|')"
[ -n "$d8" ] && [ ! -e "$d8/.git" ] && ! grep -rqs TOKEN "$d8" && ok ".git left out" || bad ".git reached the copy"

# --- a newline in a name cannot smuggle in a path from outside --------------
# find's newline-separated output split "a\n/<abs path>" into a second line,
# an absolute path that was then copied from the real filesystem.
NL="$TMP/src/nl-skill"; mkdir -p "$NL"
printf -- '---\nname: nl-skill\ndescription: t\n---\nx\n' > "$NL/SKILL.md"
# The outside file has an innocent name on purpose: id_rsa would be withheld by
# its name and the test would pass without the split ever being closed.
echo "REAL-OUTSIDE-SECRET" > "$TMP/outside/private.txt"
mkdir -p "$NL/a
$TMP/outside" && echo decoy > "$NL/a
$TMP/outside/private.txt"
out="$("$PREP" --skill "$NL" --into "$TMP/run9" 2>/dev/null)"
d9="$(sed -n 's/^skill-dir: //p' <<<"$out")"
[ -n "$d9" ] && ! grep -rqs REAL-OUTSIDE-SECRET "$d9" && ok "newline in a name pulls nothing from outside" || bad "newline smuggled an outside file in"

# --- the copy is private to the user ---------------------------------------
[ -n "$d9" ] && [ -z "$(find "$d9" -perm -004 2>/dev/null)" ] && ok "copy not world-readable" || bad "copy is world-readable"

# --- a listing that fails is a failed copy, not a smaller one ---------------
LCK="$TMP/src/lock-skill"; mkdir -p "$LCK/references/locked"
printf -- '---\nname: lock-skill\ndescription: t\n---\nx\n' > "$LCK/SKILL.md"
echo hidden > "$LCK/references/locked/a.md"; chmod 000 "$LCK/references/locked"
"$PREP" --skill "$LCK" --into "$TMP/run10" >/dev/null 2>&1; rc=$?
chmod 755 "$LCK/references/locked"
if [ "$(id -u)" = 0 ]; then ok "unreadable folder (skipped: root reads everything)"
else [ $rc -ne 0 ] && ok "unreadable folder fails the run (exit $rc)" || bad "unreadable folder: exit 0, incomplete copy advertised"; fi

# --- placeholders this script does not fill stay exactly as written ---------
POS="$TMP/src/pos-skill"; mkdir -p "$POS"
printf -- '---\nname: pos-skill\ndescription: t\n---\nFirst: $ARGUMENTS[0]\n' > "$POS/SKILL.md"
d11="$("$PREP" --skill "$POS" --into "$TMP/run11" --args "src main" 2>/dev/null | sed -n 's/^skill-dir: //p')"
grep -qxF 'First: $ARGUMENTS[0]' "$d11/SKILL.md" 2>/dev/null && ok "\$ARGUMENTS[0] left as written" || bad "\$ARGUMENTS[0]: $(grep First "$d11/SKILL.md" 2>&1)"

# --- a command inside the ARGUMENTS is the user's text, not the skill's -----
out="$("$PREP" --skill "$SUB" --into "$TMP/run12" --args 'see !`id` here' 2>/dev/null)"
grep -q '^host-command:' <<<"$out" && bad "a !\`command\` from the arguments was listed for the host" || ok "commands are listed from the skill's own text only"

# --- multi inside multi: refused here too, not only in prose ----------------
"$PREP" --skill "$HERE/../skills/ask" --into "$TMP/run13" >/dev/null 2>"$TMP/err13"; rc=$?
[ $rc -eq 3 ] && [ ! -d "$TMP/run13/skill" ] && ok "multi's own skill refused (exit 3, nothing copied)" || bad "multi skill: rc=$rc $(head -1 "$TMP/err13")"

# --- --verify: the copy may not leave with a command still in it ------------
"$PREP" --verify "$d4" >/dev/null 2>&1 && ok "--verify passes a copy with no commands" || bad "--verify failed a clean copy"
d6="$(ls -d "$TMP/run6/skill/"*/ | head -n 1)"; d6="${d6%/}"
"$PREP" --verify "$d6" >/dev/null 2>"$TMP/err14"; rc=$?
[ $rc -eq 1 ] && grep -q 'git status --short' "$TMP/err14" && ok "--verify refuses a copy with commands left, names them" || bad "--verify on unresolved copy: rc=$rc"

# --- this skill's own SKILL.md: Claude Code fills in and RUNS what is in it --
# Measured 2026-10-04: a literal $ARGUMENTS in the prose became the user's
# arguments, and an example !`command` was executed on load. Only the probe
# header may use that syntax.
SELF="$HERE/../skills/skill/SKILL.md"
n_bang="$(grep -o '!`' "$SELF" | wc -l | tr -d ' ')"
[ "$n_bang" = 1 ] && ok "skills/skill/SKILL.md: only the probe line runs a command" || bad "skills/skill/SKILL.md has $n_bang live command markers"
grep -q '\$ARGUMENTS' "$SELF" && bad "skills/skill/SKILL.md contains a live \$ARGUMENTS" || ok "skills/skill/SKILL.md: no live \$ARGUMENTS"
[ "$(grep -c 'CLAUDE_SKILL_DIR' "$SELF")" -le 2 ] && ok "skills/skill/SKILL.md: CLAUDE_SKILL_DIR only in the probe lines" || bad "skills/skill/SKILL.md mentions CLAUDE_SKILL_DIR in prose"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
