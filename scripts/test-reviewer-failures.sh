#!/usr/bin/env bash
# How a reviewer is allowed to fail. Whatever goes wrong -- a hung CLI, an
# answer in the wrong shape -- the file the judge reads must say so out loud.
# An empty or discarded file reads as "no issues found", which is the one
# outcome this plugin exists to prevent.
#
# Uses stub CLIs that just sleep, so it needs no network, no keys and no real
# CLI installed. Runs the fallback path too: on a machine with no GNU timeout
# (stock macOS) multi_timeout does the killing itself.
#
#   bash scripts/test-reviewer-failures.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
for n in codex opencode; do
  printf '#!/usr/bin/env bash\nexec sleep 300\n' > "$TMP/bin/$n"; chmod +x "$TMP/bin/$n"
done
export PATH="$TMP/bin:$PATH"
export MULTI_HOME="$TMP/home"; mkdir -p "$MULTI_HOME"
export MULTI_BACKEND_TIMEOUT=3 MULTI_CODEX_TIMEOUT=3 MULTI_REVIEW_TIMEOUT=3
echo "bash $BASH_VERSION | timeout: $(command -v timeout || echo none)"

fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1 ($2)"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

echo "== ask.sh with both CLIs hung =="
s=$SECONDS
bash "$TREE/scripts/ask.sh" --question q --backend both --model m --out-prefix "$TMP/a" --timeout "$MULTI_REVIEW_TIMEOUT" >/dev/null 2>&1
d=$((SECONDS-s))
say "returns fast (<=10s)" "$([ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
say "codex file non-empty" "$([ -s "$TMP/a-codex.txt" ] && echo yes || echo no)" "yes"
echo "   codex says:    $(head -1 "$TMP/a-codex.txt" 2>/dev/null)"
echo "   opencode says: $(head -1 "$TMP/a-opencode.txt" 2>/dev/null)"
say "codex marked TIMEOUT" "$(grep -qi 'TIMEOUT' "$TMP/a-codex.txt" && echo yes || echo no)" "yes"
say "opencode marked TIMEOUT" "$(grep -qi 'TIMEOUT' "$TMP/a-opencode.txt" && echo yes || echo no)" "yes"
say "dead markers have one-line reasons" "$([ -s "$TMP/a-codex.txt.dead" ] && [ "$(wc -l < "$TMP/a-codex.txt.dead")" -eq 1 ] && [ -s "$TMP/a-opencode.txt.dead" ] && [ "$(wc -l < "$TMP/a-opencode.txt.dead")" -eq 1 ] && echo yes || echo no)" "yes"

echo "== ask.sh codex path with codex hung =="
s=$SECONDS
bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/rc" >/dev/null 2>&1
d=$((SECONDS-s))
say "returns fast" "$([ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
echo "   says: $(head -1 "$TMP/rc-codex.txt" 2>/dev/null)"
say "not empty" "$([ -s "$TMP/rc-codex.txt" ] && echo yes || echo no)" "yes"
say "says TIMEOUT" "$(grep -qi 'TIMEOUT' "$TMP/rc-codex.txt" && echo yes || echo no)" "yes"
say "dead marker has one-line reason" "$([ -s "$TMP/rc-codex.txt.dead" ] && [ "$(wc -l < "$TMP/rc-codex.txt.dead")" -eq 1 ] && echo yes || echo no)" "yes"

echo "== backend stderr stays out of the trusted dead marker =="
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "INJECTION MARKER XYZZY" >&2
exit 7
STUB
chmod +x "$TMP/bin/codex"
bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/ri" >/dev/null 2>&1
say "dead marker has no backend log" "$(grep -q 'XYZZY' "$TMP/ri-codex.txt.dead" && echo no || echo yes)" "yes"
say "dead log preserves diagnostics" "$(grep -q 'XYZZY' "$TMP/ri-codex.txt.dead.log" && echo yes || echo no)" "yes"

echo "== read-only HOME failures get a fixed diagnosis =="
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "Error: failed to initialize in-process app-server client: Read-only file system (os error 30)" >&2
echo "INJECTION MARKER QWERTY" >&2
exit 1
STUB
chmod +x "$TMP/bin/codex"
bash "$TREE/scripts/ask.sh" --question q --backend codex --out-prefix "$TMP/rh" >/dev/null 2>&1
say "read-only marker has one-line reason" "$([ -s "$TMP/rh-codex.txt.dead" ] && [ "$(wc -l < "$TMP/rh-codex.txt.dead")" -eq 1 ] && echo yes || echo no)" "yes"
say "read-only marker names the diagnosis" "$(grep -q 'Read-only file system' "$TMP/rh-codex.txt.dead" && echo yes || echo no)" "yes"
say "read-only marker excludes other stderr" "$(grep -q 'QWERTY' "$TMP/rh-codex.txt.dead" && echo no || echo yes)" "yes"
say "read-only dead log keeps other stderr" "$(grep -q 'QWERTY' "$TMP/rh-codex.txt.dead.log" && echo yes || echo no)" "yes"

cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "Error: Unexpected error / Unknown: FileSystem.open (/read-only/home)" >&2
exit 1
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/roh" >/dev/null 2>&1
say "opencode read-only marker has one-line reason" "$([ -s "$TMP/roh-opencode.txt.dead" ] && [ "$(wc -l < "$TMP/roh-opencode.txt.dead")" -eq 1 ] && echo yes || echo no)" "yes"
say "opencode read-only marker names the diagnosis" "$(grep -q 'could not write under HOME' "$TMP/roh-opencode.txt.dead" && echo yes || echo no)" "yes"

cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo '{"type":"tool_use","part":{"state":{"output":"fixture says Read-only file system but this is repository content"}}}'
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/rhn" >/dev/null 2>&1
say "JSON repository text does not trigger HOME diagnosis" "$(grep -q 'could not write under HOME' "$TMP/rhn-opencode.txt.dead" && echo no || echo yes)" "yes"

echo "== ask.sh opencode path with opencode hung =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
exec sleep 300
STUB
chmod +x "$TMP/bin/opencode"
s=$SECONDS
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/ro" >/dev/null 2>&1
d=$((SECONDS-s))
say "returns fast" "$([ $d -le 15 ] && echo yes || echo "no(${d}s)")" "yes"
echo "   says: $(head -1 "$TMP/ro-opencode.txt" 2>/dev/null)"
say "not empty" "$([ -s "$TMP/ro-opencode.txt" ] && echo yes || echo no)" "yes"
say "says TIMEOUT" "$(grep -qi 'TIMEOUT' "$TMP/ro-opencode.txt" && echo yes || echo no)" "yes"
say "dead marker has one-line reason" "$([ -s "$TMP/ro-opencode.txt.dead" ] && [ "$(wc -l < "$TMP/ro-opencode.txt.dead")" -eq 1 ] && echo yes || echo no)" "yes"

echo "== opencode silent stall fails before the backend timeout =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "$$" > "$STUB_PIDFILE"
exec sleep 300
STUB
chmod +x "$TMP/bin/opencode"
s=$SECONDS
STUB_PIDFILE="$TMP/os.pid" MULTI_OPENCODE_STALL=2 MULTI_BACKEND_TIMEOUT=30 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/os" >/dev/null 2>&1
d=$((SECONDS-s))
say "silent stall returns well before timeout" "$([ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
say "silent stall has a one-line marker" "$([ -s "$TMP/os-opencode.txt.dead" ] && [ "$(wc -l < "$TMP/os-opencode.txt.dead")" -eq 1 ] && echo yes || echo no)" "yes"
say "silent stall says SILENT" "$(grep -q 'SILENT' "$TMP/os-opencode.txt.dead" && echo yes || echo no)" "yes"
pid="$(cat "$TMP/os.pid")"; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n+1)); done
say "silent stall process is gone" "$(kill -0 "$pid" 2>/dev/null && echo no || echo yes)" "yes"

echo "== opencode stderr does not disarm the silent stall watchdog =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "warning: something" >&2
echo "$$" > "$STUB_PIDFILE"
exec sleep 300
STUB
chmod +x "$TMP/bin/opencode"
s=$SECONDS
STUB_PIDFILE="$TMP/ow.pid" MULTI_OPENCODE_STALL=2 MULTI_BACKEND_TIMEOUT=30 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/ow" >/dev/null 2>&1
d=$((SECONDS-s))
say "stderr-only stall returns well before timeout" "$([ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
say "stderr-only stall says SILENT" "$(grep -q 'SILENT' "$TMP/ow-opencode.txt.dead" && echo yes || echo no)" "yes"
say "stderr-only stall does not say TIMEOUT" "$(grep -q 'TIMEOUT' "$TMP/ow-opencode.txt.dead" && echo no || echo yes)" "yes"
pid="$(cat "$TMP/ow.pid")"; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n+1)); done
say "stderr-only stalled process is gone" "$(kill -0 "$pid" 2>/dev/null && echo no || echo yes)" "yes"

echo "== fallback starts with an empty raw event stream =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$model" in
  primary) echo '{"type":"error","error":"primary failed"}'; exit 1 ;;
  backup) echo "$$" > "$STUB_PIDFILE"; exec sleep 300 ;;
esac
STUB
chmod +x "$TMP/bin/opencode"
s=$SECONDS
STUB_PIDFILE="$TMP/fs.pid" MULTI_OPENCODE_STALL=2 MULTI_BACKEND_TIMEOUT=30 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model primary --fallback backup --out-prefix "$TMP/fs" >/dev/null 2>&1
d=$((SECONDS-s))
say "silent fallback returns well before timeout" "$([ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
say "silent fallback is reported SILENT" "$(grep -q 'SILENT' "$TMP/fs-opencode.txt.dead" && echo yes || echo no)" "yes"
say "silent fallback is not reported TIMEOUT" "$(grep -q 'TIMEOUT' "$TMP/fs-opencode.txt.dead" && echo no || echo yes)" "yes"
pid="$(cat "$TMP/fs.pid")"; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n+1)); done
say "silent fallback process is gone" "$(kill -0 "$pid" 2>/dev/null && echo no || echo yes)" "yes"

echo "== stall deadline at or past timeout is disabled =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
exec sleep 300
STUB
chmod +x "$TMP/bin/opencode"
s=$SECONDS
MULTI_OPENCODE_STALL=5 MULTI_BACKEND_TIMEOUT=3 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/sd" >/dev/null 2>&1
d=$((SECONDS-s))
say "disabled stall reaches normal timeout" "$([ $d -ge 3 ] && [ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
say "disabled stall says TIMEOUT" "$(grep -q 'TIMEOUT' "$TMP/sd-opencode.txt.dead" && echo yes || echo no)" "yes"
say "disabled stall does not say SILENT" "$(grep -q 'SILENT' "$TMP/sd-opencode.txt.dead" && echo no || echo yes)" "yes"

MULTI_OPENCODE_STALL=bad MULTI_BACKEND_TIMEOUT=3 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/sv" >"$TMP/sv.stdout" 2>"$TMP/sv.stderr"
say "invalid stall falls back without integer errors" "$(grep -q 'integer expression' "$TMP/sv.stderr" && echo no || echo yes)" "yes"
say "invalid stall reaches TIMEOUT" "$(grep -q 'TIMEOUT' "$TMP/sv-opencode.txt.dead" && echo yes || echo no)" "yes"

echo "== an initial opencode event disables the stall watchdog =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo '{"type":"step_start","timestamp":1000,"part":{}}'
exec sleep 300
STUB
chmod +x "$TMP/bin/opencode"
s=$SECONDS
MULTI_OPENCODE_STALL=1 MULTI_BACKEND_TIMEOUT=3 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/oe" >/dev/null 2>&1
d=$((SECONDS-s))
say "eventful run reaches normal timeout" "$([ $d -ge 3 ] && [ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
say "eventful timeout says TIMEOUT" "$(grep -q 'TIMEOUT' "$TMP/oe-opencode.txt.dead" && echo yes || echo no)" "yes"
say "eventful timeout does not say SILENT" "$(grep -q 'SILENT' "$TMP/oe-opencode.txt.dead" && echo no || echo yes)" "yes"

echo "== opencode silent primary falls back to an answer =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$model" in
  primary) echo "$$" > "$STUB_PIDFILE"; exec sleep 300 ;;
  backup) echo '{"type":"text","timestamp":1200,"part":{"text":"silent fallback answer"}}' ;;
esac
STUB
chmod +x "$TMP/bin/opencode"
STUB_PIDFILE="$TMP/sf.pid" MULTI_OPENCODE_STALL=2 MULTI_BACKEND_TIMEOUT=30 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model primary --fallback backup --out-prefix "$TMP/sf" >/dev/null 2>&1
say "silent fallback answer kept" "$(grep -c 'silent fallback answer' "$TMP/sf-opencode.txt")" "1"
say "silent fallback stays live" "$([ ! -e "$TMP/sf-opencode.txt.dead" ] && echo yes || echo no)" "yes"
say "silent fallback banner is loud" "$(sed -n 1p "$TMP/sf-opencode.txt")" "opencode: primary emitted nothing for 2s — fell back to backup"
pid="$(cat "$TMP/sf.pid")"; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n+1)); done
say "silent primary process is gone" "$(kill -0 "$pid" 2>/dev/null && echo no || echo yes)" "yes"

echo "== terminating ask.sh marks and stops unfinished backends =="
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "$$" > "$CODEX_STUB_PIDFILE"
exec sleep 300
STUB
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "$$" > "$OPENCODE_STUB_PIDFILE"
exec sleep 300
STUB
chmod +x "$TMP/bin/codex" "$TMP/bin/opencode"
CODEX_STUB_PIDFILE="$TMP/kt-codex.pid" OPENCODE_STUB_PIDFILE="$TMP/kt-opencode.pid" \
  MULTI_CODEX_TIMEOUT=30 MULTI_BACKEND_TIMEOUT=30 MULTI_OPENCODE_STALL=30 \
  bash "$TREE/scripts/ask.sh" --question q --backend both --model m --timeout 30 --out-prefix "$TMP/kt" >/dev/null 2>&1 &
ask_pid=$!
n=0
while { [ ! -s "$TMP/kt-codex.pid" ] || [ ! -s "$TMP/kt-opencode.pid" ]; } && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
s=$SECONDS
kill -TERM "$ask_pid"
wait "$ask_pid"; ask_rc=$?
d=$((SECONDS-s))
say "terminated ask exits 143" "$ask_rc" "143"
say "terminated ask returns within 5s" "$([ $d -le 5 ] && echo yes || echo "no(${d}s)")" "yes"
say "terminated codex marker is one-line KILLED" "$([ -s "$TMP/kt-codex.txt.dead" ] && [ "$(wc -l < "$TMP/kt-codex.txt.dead")" -eq 1 ] && grep -q 'KILLED' "$TMP/kt-codex.txt.dead" && echo yes || echo no)" "yes"
say "terminated opencode marker is one-line KILLED" "$([ -s "$TMP/kt-opencode.txt.dead" ] && [ "$(wc -l < "$TMP/kt-opencode.txt.dead")" -eq 1 ] && grep -q 'KILLED' "$TMP/kt-opencode.txt.dead" && echo yes || echo no)" "yes"
pid="$(cat "$TMP/kt-opencode.pid")"; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n+1)); done
gone="$(kill -0 "$pid" 2>/dev/null && echo no || echo yes)"
say "terminated opencode process is gone" "$gone" "yes"
pid="$(cat "$TMP/kt-codex.pid")"; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n+1)); done
say "terminated codex process is gone" "$(kill -0 "$pid" 2>/dev/null && echo no || echo yes)" "yes"

echo "== termination preserves a backend that already finished =="
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "finished codex answer" > "$out"
STUB
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "$$" > "$OPENCODE_STUB_PIDFILE"
exec sleep 300
STUB
chmod +x "$TMP/bin/codex" "$TMP/bin/opencode"
OPENCODE_STUB_PIDFILE="$TMP/kf-opencode.pid" MULTI_CODEX_TIMEOUT=30 MULTI_BACKEND_TIMEOUT=30 MULTI_OPENCODE_STALL=29 \
  bash "$TREE/scripts/ask.sh" --question q --backend both --model m --timeout 30 --out-prefix "$TMP/kf" >/dev/null 2>&1 &
ask_pid=$!
n=0
while { [ ! -s "$TMP/kf-codex.txt" ] || [ -e "$TMP/kf-codex.txt.running" ] || [ ! -s "$TMP/kf-opencode.pid" ]; } && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
kill -TERM "$ask_pid"
wait "$ask_pid"; ask_rc=$?
say "mixed termination exits 143" "$ask_rc" "143"
say "finished codex answer is intact" "$(cat "$TMP/kf-codex.txt")" "finished codex answer"
say "finished codex has no dead marker" "$([ ! -e "$TMP/kf-codex.txt.dead" ] && echo yes || echo no)" "yes"
say "only unfinished opencode is KILLED" "$([ -s "$TMP/kf-opencode.txt.dead" ] && grep -q 'KILLED' "$TMP/kf-opencode.txt.dead" && echo yes || echo no)" "yes"
pid="$(cat "$TMP/kf-opencode.pid")"; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n+1)); done
say "mixed termination opencode process is gone" "$(kill -0 "$pid" 2>/dev/null && echo no || echo yes)" "yes"

echo "== opencode walks the fallback list until a later model answers =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$model" in
  primary|backup1) echo '{"type":"step_start","timestamp":1000,"part":{}}' ;;
  timeout) exec sleep 300 ;;
  partialsmall) echo '{"type":"text","timestamp":1100,"part":{"text":"small timeout partial"}}'; exit 124 ;;
  partialbest) echo '{"type":"text","timestamp":1100,"part":{"text":"best timeout partial with more useful detail"}}'; exit 124 ;;
  timeoutpartial) echo '{"type":"text","timestamp":1100,"part":{"text":"primary timeout partial"}}'; exit 124 ;;
  backup2) echo '{"type":"text","timestamp":1200,"part":{"text":"later fallback answer"}}' ;;
  *) echo '{"type":"step_start","timestamp":1000,"part":{}}' ;;
esac
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model primary --fallback backup1,backup2 --out-prefix "$TMP/fl" >/dev/null 2>&1
say "later fallback answer kept" "$(grep -c 'later fallback answer' "$TMP/fl-opencode.txt")" "1"
say "later fallback stays live" "$([ ! -e "$TMP/fl-opencode.txt.dead" ] && echo yes || echo no)" "yes"
say "loud fallback banner present" "$(sed -n 1p "$TMP/fl-opencode.txt" | grep -c 'primary produced no answer — fell back to backup2')" "1"
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model timeout --fallback backup2 --timeout 1 --out-prefix "$TMP/ft" >/dev/null 2>&1
say "timeout advances to fallback" "$(grep -c 'later fallback answer' "$TMP/ft-opencode.txt")" "1"
say "timeout fallback stays live" "$([ ! -e "$TMP/ft-opencode.txt.dead" ] && echo yes || echo no)" "yes"

bash "$TREE/scripts/ask.sh" --question q --backend opencode --model primary --fallback partialsmall,partialbest,backup1 --out-prefix "$TMP/fp" >/dev/null 2>&1
say "best intermediate timeout partial kept" "$(grep -c 'best timeout partial with more useful detail' "$TMP/fp-opencode.txt")" "1"
say "smaller timeout partial discarded" "$(grep -c 'small timeout partial' "$TMP/fp-opencode.txt")" "0"
say "intermediate partial marked TIMEOUT" "$(grep -c '^opencode: TIMEOUT after .* (partial; run was cut off)' "$TMP/fp-opencode.txt")" "1"
say "intermediate partial stays live" "$([ ! -e "$TMP/fp-opencode.txt.dead" ] && echo yes || echo no)" "yes"

bash "$TREE/scripts/ask.sh" --question q --backend opencode --model timeoutpartial --fallback backup2 --out-prefix "$TMP/fb" >/dev/null 2>&1
say "timeout fallback banner names timeout" "$(sed -n 1p "$TMP/fb-opencode.txt")" "opencode: timeoutpartial timed out after ${MULTI_BACKEND_TIMEOUT}s — fell back to backup2"

echo "== an opencode too old for --format json still reaches the judge =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
printf '\033[32m> build - deepseek\033[0m\n'
echo "I looked at the diff. The retry loop in worker.py can spin forever when"
echo "the queue is empty, and nobody resets the counter."
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/off" >/dev/null 2>&1
say "labelled as a raw capture" "$(grep -q 'RAW CAPTURE ONLY' "$TMP/off-opencode.txt" && echo yes || echo no)" "yes"
say "the answer survived" "$(grep -q 'retry loop in worker.py' "$TMP/off-opencode.txt" && echo yes || echo no)" "yes"
say "ANSI stripped" "$(LC_ALL=C grep -q "$(printf '\033')" "$TMP/off-opencode.txt" && echo no || echo yes)" "yes"
say "raw capture is not marked dead" "$([ ! -e "$TMP/off-opencode.txt.dead" ] && echo yes || echo no)" "yes"

echo "== a hang that printed a header is not an answer =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "> build - deepseek"   # opencode prints this within a second
exec sleep 300
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/p" >/dev/null 2>&1
rcode=$?
say "partial transcript marked TIMEOUT" "$(grep -c 'TIMEOUT' "$TMP/p-opencode.txt")" "1"
say "not counted as a live backend" "$rcode" "1"

echo "== a timed-out JSON run keeps its rendered partial answer =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo '{"type":"text","timestamp":1000,"part":{"text":"src/partial.py:7 | MEDIUM | rendered before timeout"}}'
exec sleep 300
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/j" >/dev/null 2>&1
say "rendered partial answer kept" "$(grep -c 'rendered before timeout' "$TMP/j-opencode.txt")" "1"
say "partial answer marked TIMEOUT" "$(grep -ci 'TIMEOUT.*partial' "$TMP/j-opencode.txt")" "1"
say "rendered partial stays live" "$([ ! -e "$TMP/j-opencode.txt.dead" ] && echo yes || echo no)" "yes"


echo "== a CLI that ignores SIGTERM is still killed =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
trap '' TERM
exec sleep 300
STUB
chmod +x "$TMP/bin/opencode"
s=$SECONDS
MULTI_TIMEOUT_GRACE=3 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/k" >/dev/null 2>&1
d=$((SECONDS-s))
say "killed within grace" "$([ $d -le 15 ] && echo yes || echo "no(${d}s)")" "yes"
say "reported as a timeout" "$(grep -c 'TIMEOUT' "$TMP/k-opencode.txt")" "1"


# A timed-out openrouter reviewer has two causes that look identical from the
# outside -- both leave an empty file -- and the message used to name only one
# of them ("the key was probably rejected"). Measured 2026-09-02: that sent a
# reader hunting a healthy key while the model had done 36 real turns and only
# needed more time. The stub `claude` writes a transcript at the session id it
# was handed, so the two cases are told apart here with no network and no key.
echo "== openrouter timeout distinguishes a working model from a dead key =="
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Find --session-id and write TURNS assistant lines where the runner looks.
sid=""
while [ $# -gt 0 ]; do
  [ "$1" = "--session-id" ] && { sid="$2"; shift 2; continue; }
  shift
done
# STUB_TURNS unset => write no transcript at all (the "child never started"
# shape). STUB_TURNS set, even to 0, => a transcript that always opens with the
# user turn, because that is what a real rejected key leaves behind: the prompt
# went in, nothing came back. Without that line a 0-turn run would take the
# no-transcript branch and the zero-assistant branch would go untested.
if [ -n "$sid" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -n "${STUB_TURNS:-}" ]; then
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/stub"
  f="$CLAUDE_CONFIG_DIR/projects/stub/$sid.jsonl"
  echo '{"type":"user"}' > "$f"
  n=0
  while [ "$n" -lt "$STUB_TURNS" ]; do
    echo '{"type":"assistant"}' >> "$f"
    n=$((n+1))
  done
fi
exec sleep 300
STUB
chmod +x "$TMP/bin/claude"
export OPENROUTER_API_KEY=stub-key-not-used-by-the-stub

STUB_TURNS=9 bash "$TREE/scripts/ask.sh" --question q --backend openrouter:m --out-prefix "$TMP/or" >/dev/null 2>&1
echo "   busy says: $(head -c 160 "$TMP/or-openrouter.txt" 2>/dev/null)"
say "busy model: counts its turns" "$(grep -c 'made 9 model turns' "$TMP/or-openrouter.txt")" "1"
say "busy model: blames the timeout" "$(grep -c 'MULTI_REVIEW_TIMEOUT' "$TMP/or-openrouter.txt")" "1"
say "busy model: does NOT blame the key" "$(grep -qi 'rejected key' "$TMP/or-openrouter.txt" && echo no || echo yes)" "yes"
say "busy model: points at the transcript" "$(grep -c '\.jsonl' "$TMP/or-openrouter.txt")" "1"

# One turn is the ambiguous middle -- a slow single turn inside a short budget
# looks the same as a key dying mid-retry -- and must be reported as ambiguous.
STUB_TURNS=1 bash "$TREE/scripts/ask.sh" --question q --backend openrouter:m --out-prefix "$TMP/oa" >/dev/null 2>&1
say "one turn: names the count, not a cause" "$(grep -c 'Only 1 model turns recorded' "$TMP/oa-openrouter.txt")" "1"
say "one turn: does NOT blame the timeout" "$(grep -q 'MULTI_REVIEW_TIMEOUT' "$TMP/oa-openrouter.txt" && echo no || echo yes)" "yes"

# A transcript that exists and holds zero assistant turns: the shape a really
# rejected key leaves. It must offer the key AND the alternatives (a pool that
# went 429 after the probe passed, a transcript format this code stopped
# recognising) -- never one cause stated as settled.
STUB_TURNS=0 bash "$TREE/scripts/ask.sh" --question q --backend openrouter:m --out-prefix "$TMP/od" >/dev/null 2>&1
echo "   zero says: $(head -c 200 "$TMP/od-openrouter.txt" 2>/dev/null)"
say "zero turns: transcript branch, not no-transcript" "$(grep -c 'Only 0 model turns recorded' "$TMP/od-openrouter.txt")" "1"
say "zero turns: offers the key" "$(grep -ci 'rejected key' "$TMP/od-openrouter.txt")" "1"
say "zero turns: offers a busy pool too" "$(grep -c '429' "$TMP/od-openrouter.txt")" "1"
say "zero turns: offers format drift too" "$(grep -c 'format this code no longer recognises' "$TMP/od-openrouter.txt")" "1"

# No transcript at all is a different case from an empty one, and says so.
bash "$TREE/scripts/ask.sh" --question q --backend openrouter:m --out-prefix "$TMP/on" >/dev/null 2>&1
say "no transcript: says exactly that" "$(grep -c 'No transcript was written at all' "$TMP/on-openrouter.txt")" "1"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
