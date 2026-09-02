#!/usr/bin/env bash
# One directory per session, all of them under one parent, and old ones swept.
# The slug is a label, not the identity: a caller that words it differently in
# a later command must still land in the same directory, or the reviewers end
# up writing into two places and half the run goes missing.
#
#   bash scripts/test-run-dir.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MULTI_RUN_BASE="$TMP/multi"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

export CLAUDE_CODE_SESSION_ID=aaaa-1111
a="$(bash "$TREE/scripts/run-dir.sh" --slug 'Skills: fixing MULTI!!')"
say "slug becomes a path" "${a##*/}" "aaaa-1111--skills-fixing-multi"
say "directory exists" "$([ -d "$a" ] && echo yes || echo no)" "yes"

b="$(bash "$TREE/scripts/run-dir.sh" --slug something-else-entirely)"
say "same session, same directory" "$b" "$a"

c="$(bash "$TREE/scripts/run-dir.sh")"
say "no slug at all still lands there" "$c" "$a"

CLAUDE_CODE_SESSION_ID=bbbb-2222 d="$(CLAUDE_CODE_SESSION_ID=bbbb-2222 bash "$TREE/scripts/run-dir.sh" --slug other-job)"
say "another session gets its own" "$([ "$d" != "$a" ] && echo yes || echo no)" "yes"
say "both live under one parent" "$(/bin/ls -1 "$MULTI_RUN_BASE" | wc -l | tr -d ' ')" "2"

echo "== old runs are swept =="
old="$MULTI_RUN_BASE/cccc-3333--ancient"
mkdir -p "$old"
# 30 days ago; touch -t needs a timestamp, and -d is GNU-only, so use find's
# own view of age by backdating with touch -t on a fixed old date.
touch -t 202601010000 "$old" 2>/dev/null || touch -t 202601010000 "$old"
CLAUDE_CODE_SESSION_ID=dddd-4444 bash "$TREE/scripts/run-dir.sh" --slug fresh >/dev/null
say "week-old run removed" "$([ -d "$old" ] && echo still-there || echo gone)" "gone"
say "current runs untouched" "$([ -d "$a" ] && echo yes || echo no)" "yes"

old2="$MULTI_RUN_BASE/ffff-6666--ancient-kept"
mkdir -p "$old2"; touch -t 202601010000 "$old2"
CLAUDE_CODE_SESSION_ID=eeee-5555 MULTI_RUN_KEEP_DAYS=0 bash "$TREE/scripts/run-dir.sh" --slug x >/dev/null
say "sweep can be turned off" "$([ -d "$old2" ] && echo kept || echo swept)" "kept"

echo "== no session id: MULTI_RUN_ID gives each run its own identity =="
# Outside Claude Code there is no session id, and every non-CC run would key on
# the same 'shared', so two of them collide in one directory. MULTI_RUN_ID is
# the escape hatch: give concurrent non-CC runs distinct ids and they stay apart.
j1="$(env -u CLAUDE_CODE_SESSION_ID MULTI_RUN_ID=job-one bash "$TREE/scripts/run-dir.sh" --slug alpha)"
j2="$(env -u CLAUDE_CODE_SESSION_ID MULTI_RUN_ID=job-two bash "$TREE/scripts/run-dir.sh" --slug beta)"
say "different MULTI_RUN_ID -> different directory" "$([ "$j1" != "$j2" ] && echo yes || echo no)" "yes"
# And it still behaves like the session id: same id, later block, same directory.
j1b="$(env -u CLAUDE_CODE_SESSION_ID MULTI_RUN_ID=job-one bash "$TREE/scripts/run-dir.sh" --slug gamma)"
say "same MULTI_RUN_ID -> same directory across blocks" "$j1b" "$j1"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
