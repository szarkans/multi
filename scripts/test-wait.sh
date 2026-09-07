#!/usr/bin/env bash
# A running backend must be told apart from a dead one, and one run must never
# start on top of another. The judge used to read an empty answer beside an
# empty .running as "did not answer" (#27), and a second ask.sh on the same
# prefix rm -f'd the answer files a still-running claude was writing into --
# its answer landed in a deleted inode and the runner said NO OUTPUT
# (measured 2026-09-07, four reviews on one $RUN/review).
#
# Stub codex only: no network, no keys.
#
#   bash scripts/test-wait.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/h"
# codex stub: sleep, then write the answer to the -o path
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
sleep "${STUB_SLEEP:-4}"; echo "answer" > "$out"
STUB
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/h"
printf 'default_profile="p"\n[backends.codex]\ntype="codex"\ntimeout=30\n[backends.openrouter]\ntype="claude-headless"\nbase_url="https://openrouter.ai/api"\nmodels=["m"]\n[profiles]\np=["codex","openrouter"]\n' > "$MULTI_HOME/config.toml"
unset OPENROUTER_API_KEY   # openrouter fails at once with NO KEY: the "dead" row
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

echo "== .running says who, since when, for how long =="
bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r" >"$TMP/ask.log" 2>&1 &
apid=$!
n=0; while [ ! -s "$TMP/r-codex.txt.running" ] && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n+1)); done
read -r pid start timeout < "$TMP/r-codex.txt.running"
say "pid is a live runner, not ask.sh itself" "$([ "$pid" != "$apid" ] && kill -0 "$pid" 2>/dev/null && echo yes || echo no)" "yes"
say "start is an epoch near now" "$([ "$start" -gt $(( $(date +%s) - 10 )) ] && echo yes || echo no)" "yes"
say "timeout is the backend's" "$timeout" "30"

echo "== a second run on a live prefix is refused, the first is untouched =="
err="$(bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r" 2>&1 >/dev/null)"; rc=$?
say "exit 2" "$rc" "2"
say "names the backend and wait.sh" "$(printf '%s' "$err" | grep -c 'codex.*wait.sh')" "1"
say "first run still marked running" "$([ -e "$TMP/r-codex.txt.running" ] && echo yes || echo no)" "yes"
say "another prefix is fine" "$(bash "$TREE/scripts/ask.sh" --question q --backend openrouter --out-prefix "$TMP/other" >/dev/null 2>&1; [ -e "$TMP/other-openrouter.txt.dead" ] && echo ran || echo no)" "ran"

echo "== wait.sh --max reports a running backend and returns 1 =="
out="$(bash "$TREE/scripts/wait.sh" --prefix "$TMP/r" --max 1)"; rc=$?
say "exit 1 while running" "$rc" "1"
say "codex row says still running with its timeout" "$(printf '%s\n' "$out" | grep -c '^codex .*still running (timeout 30s)')" "1"
say "openrouter row says FAILED with the .dead text" "$(printf '%s\n' "$out" | grep -c '^openrouter .*FAILED: openrouter: NO KEY')" "1"

echo "== wait.sh without --max blocks to the end =="
out="$(bash "$TREE/scripts/wait.sh" --prefix "$TMP/r")"; rc=$?
wait "$apid"
say "exit 0 when done" "$rc" "0"
say "codex row is ok with a duration" "$(printf '%s\n' "$out" | grep -c '^codex  *[0-9]*s  *ok$')" "1"
say "no .running left" "$(ls "$TMP"/r-*.running 2>/dev/null | wc -l | tr -d ' ')" "0"
say "roster names both, then a duration line each" "$(awk 'NF==1' "$TMP/r.run" | tr '\n' ' '):$(awk 'NF==2{print $1}' "$TMP/r.run" | sort | tr '\n' ' ')" "codex openrouter :codex openrouter "
say "codex took at least the stub's sleep" "$([ "$(awk 'NF==2 && $1=="codex"{print $2}' "$TMP/r.run")" -ge 3 ] && echo yes || echo no)" "yes"

echo "== after the run a new one on the same prefix is allowed =="
STUB_SLEEP=0 bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/r" >/dev/null 2>&1
say "exit 0" "$?" "0"
say "the roster was reset for the new run" "$(wc -l < "$TMP/r.run" | tr -d ' ')" "2"

echo "== a stale .running from a killed ask.sh does not block =="
echo "999999999 1 30" > "$TMP/r-codex.txt.running"
STUB_SLEEP=0 bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/r" >/dev/null 2>&1
say "runs" "$?" "0"
: > "$TMP/r-codex.txt.running"   # pre-1.11 empty marker
STUB_SLEEP=0 bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/r" >/dev/null 2>&1
say "an old empty marker does not block either" "$?" "0"

echo "== wait.sh on a killed run: a marker nobody owns, no .dead =="
mkdir -p "$TMP/k"; echo codex > "$TMP/k/x.run"; echo "999999999 1 30" > "$TMP/k/x-codex.txt.running"; echo "half an answer" > "$TMP/k/x-codex.txt"
out="$(bash "$TREE/scripts/wait.sh" --prefix "$TMP/k/x")"; rc=$?
say "returns 0 (nothing is running)" "$rc" "0"
say "a partial answer under a dead marker is not ok" "$(printf '%s\n' "$out" | grep -c 'FAILED: killed before it finished')" "1"
say "unknown prefix is exit 2" "$(bash "$TREE/scripts/wait.sh" --prefix "$TMP/nothing" >/dev/null 2>&1; echo $?)" "2"

echo "== a run beside it with a longer prefix is not this run =="
bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/r-2" >/dev/null 2>&1 &
bpid=$!; sleep 1
out="$(bash "$TREE/scripts/wait.sh" --prefix "$TMP/r" --max 1)"; rc=$?
say "wait.sh on r ignores r-2's live backend" "$rc:$(printf '%s\n' "$out" | grep -c '^2-codex')" "0:0"
STUB_SLEEP=0 bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/r" >/dev/null 2>&1
say "ask.sh on r is not blocked by r-2" "$?" "0"
wait "$bpid"

echo "== the backend outlives a SIGKILLed ask.sh, and the marker knows =="
bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/o" >/dev/null 2>&1 &
opid=$!; sleep 1
kill -KILL "$opid"; wait "$opid" 2>/dev/null
read -r mpid _ < "$TMP/o-codex.txt.running"
say "marker holds the runner's pid, not the dead ask.sh's" "$([ "$mpid" != "$opid" ] && kill -0 "$mpid" 2>/dev/null && echo yes || echo no)" "yes"
bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/o" >/dev/null 2>&1
say "a new run on that prefix is still refused" "$?" "2"
out="$(bash "$TREE/scripts/wait.sh" --prefix "$TMP/o")"; rc=$?
say "wait.sh waits for the orphan and reports it ok" "$rc:$(printf '%s\n' "$out" | grep -c '^codex .* ok$')" "0:1"

echo "== a run in the same second is serialised, not interleaved =="
rm -f "$TMP"/s*
bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/s" >>"$TMP/s.log" 2>&1 &
p1=$!
bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/s" >>"$TMP/s.log" 2>&1 &
p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
say "exactly one of two simultaneous runs was refused" "$(( (r1==2) + (r2==2) ))" "1"
say "no lock left behind" "$([ -e "$TMP/s.lock" ] && echo yes || echo no)" "no"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
