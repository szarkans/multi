#!/usr/bin/env bash
# The pool probe retries one transient 429 and preserves bounded diagnostics.
# All HTTP requests go to this suite's loopback server; no backend or spend.
#
#   bash scripts/test-pool-probe.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL: mktemp failed" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: no temporary directory" >&2; exit 1; }
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/probes"
export MULTI_HOME="$TMP/home" MULTI_CONFIG="$TMP/home/config.toml"
export MULTI_PROVIDERS_ENV="$TMP/home/providers.env" TMPDIR="$TMP/probes"
# No installed CLI or inherited provider configuration participates in setup.
unset OPENROUTER_API_KEY GEMINI_API_KEY
for cli in codex opencode gemini claude; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/$cli"
  chmod +x "$TMP/bin/$cli"
done
export PATH="$TMP/bin:$PATH"
export NO_PROXY=127.0.0.1 no_proxy=127.0.0.1
. "$TREE/scripts/providers.sh"
py="$(multi_python)" || { echo "FAIL: no working Python"; exit 1; }
cat > "$TMP/server.py" <<'PY'
import glob, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

counts = {}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model = request['model']
        counts[model] = counts.get(model, 0) + 1
        attempt = counts[model]
        valid = (self.path == '/v1/messages' and
                 self.headers.get('Authorization') == 'Bearer fixture-key' and
                 self.headers.get('anthropic-version') == '2023-06-01' and
                 request['max_tokens'] == 1 and
                 request['messages'] == [{'role': 'user', 'content': 'hi'}])
        with open(sys.argv[2], 'a') as f:
            f.write(f'{model}\t{time.monotonic()}\t{valid}\n')
        code, body, headers = 429, b'', {}
        if model.startswith('recover') and attempt > 1 or model == 'ok':
            code = 200
        elif model.startswith('quota'):
            body = b'{"error":{"message":"Account quota exhausted"}}'
        elif model == 'spike':
            body = b'Provider temporarily overloaded'
        elif model == 'headers':
            headers = {'rEtRy-AfTeR': '3600', 'X-RateLimit-Remaining': '0',
                       'RateLimit-Reset': '42', 'Set-Cookie': 'PRIVATE_COOKIE'}
        elif model == 'dirty':
            body = ('quota\n\t\x1b[31m\x00\r fixture-key \u0085 \u202e Лимит').encode()
            headers = {'X-RateLimit-Note': 'busy\t\x1b[31m fixture-key'}
        elif model == 'long':
            body = b'q' * 500 + b'TAIL_SENTINEL'
            headers = {'X-RateLimit-Remaining': '0'}
        elif model.startswith('unicode'):
            body = ('Лимит ' * 100).encode()
        elif model == 'changes':
            code = 429 if attempt == 1 else 503
            body = b'First spike' if attempt == 1 else b'Upstream unavailable'
        elif model == 'empty-retry':
            body = b'Quota was exhausted' if attempt == 1 else b''
        elif model in ('retry-disconnect', 'retry-bare-503'):
            body = b'First spike'
            if attempt > 1:
                if model == 'retry-disconnect':
                    self.close_connection = True
                    return
                code, body = 503, b''
        elif model in ('huge', 'stream'):
            body = b'q' * (1024 * 1024) + b'TAIL_SENTINEL'
        elif model.startswith('error-'):
            code = int(model.split('-')[1])
            body = b'Must not change the old wording'
        elif model == 'disconnect':
            self.close_connection = True
            return
        elif model == 'timeout':
            time.sleep(11)
        self.send_response(code)
        for name, value in headers.items():
            self.send_header(name, value)
        if model != 'stream':
            self.send_header('Content-Length', str(len(body) + (1 if model == 'partial-timeout' else 0)))
        else:
            self.send_header('Connection', 'close')
            self.close_connection = True
        self.end_headers()
        if model in ('huge', 'stream'):
            maximum = 0
            for start in range(0, len(body), 16384):
                self.wfile.write(body[start:start + 16384])
                self.wfile.flush()
                time.sleep(0.002)
                for path in glob.glob(os.path.join(sys.argv[3], '*', '*')):
                    try:
                        maximum = max(maximum, os.path.getsize(path))
                    except FileNotFoundError:
                        pass
            with open(sys.argv[4], 'a') as f:
                f.write(f'{model}\t{maximum}\n')
            return
        self.wfile.write(body)
        if model == 'partial-timeout':
            self.wfile.flush()
            time.sleep(11)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
"$py" "$TMP/server.py" "$TMP/port" "$TMP/requests" "$TMP/probes" "$TMP/disk-sizes" > "$TMP/server.log" 2>&1 &
server_pid=$!
n=0
while [ ! -s "$TMP/port" ] && [ "$n" -lt 100 ]; do
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
  n=$((n+1))
done
[ -s "$TMP/port" ] || { cat "$TMP/server.log"; echo "FAIL: fake endpoint did not start"; exit 1; }
url="http://127.0.0.1:$(cat "$TMP/port")"
fail=0
say() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
requests() { awk -F '\t' -v m="$1" '$1==m {n++} END {print n+0}' "$TMP/requests"; }
contains() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "== transient 429 keeps the preferred model =="
out="$(multi_pick_live_model "$url" fixture-key recover-first ok)"; rc=$?
say "preferred model picked with no skipped line" "$out" "recover-first"
say "success status preserved" "$rc" "0"
say "exactly one extra request" "$(requests recover-first)" "2"
say "fallback was never probed" "$(requests ok)" "0"
say "fixed delay is short and at least one second" "$("$py" - "$TMP/requests" <<'PY'
import sys
times = [float(line.split('\t')[1]) for line in open(sys.argv[1]) if line.startswith('recover-first\t')]
print('yes' if 1 <= times[1] - times[0] < 5 else 'no')
PY
)" "yes"

echo "== persistent quota and provider spike stay distinguishable =="
quota="$(MULTI_POOL_PROBE_LOG="$TMP/quota-reason" multi_pick_live_model "$url" fixture-key quota-first ok)"; rc=$?
say "fallback succeeds" "$rc" "0"
say "model is still the first line" "$(printf '%s\n' "$quota" | head -1)" "ok"
say "skipped line has only the closed-set verdict" "$(contains "$quota" 'quota-first (RATE LIMITED (HTTP 429))')" "yes"
say "quota body withheld from the skipped line" "$(contains "$quota" 'Account quota exhausted')" "no"
say "quota body preserved separately as endpoint text" "$(contains "$(cat "$TMP/quota-reason")" 'endpoint text (untrusted): {"error":{"message":"Account quota exhausted"}}')" "yes"
say "picker still has two lines" "$(printf '%s\n' "$quota" | wc -l | tr -d ' ')" "2"
say "persistent 429 makes exactly two requests" "$(requests quota-first)" "2"
spike="$(MULTI_POOL_PROBE_LOG="$TMP/spike-reason" multi_pick_live_model "$url" fixture-key spike ok)"
say "spike reason is different" "$(contains "$(cat "$TMP/spike-reason")" 'Provider temporarily overloaded')" "yes"
say "spike reason withheld from picker stdout" "$(contains "$spike" 'Provider temporarily overloaded')" "no"
say "spike makes exactly two requests" "$(requests spike)" "2"
all_busy="$(multi_pick_live_model "$url" fixture-key quota-all)"; rc=$?
say "all busy status preserved" "$rc" "1"
say "all busy has an empty model line" "$(printf '%s\n' "$all_busy" | head -1)" ""
say "all busy still has two lines" "$(printf '%s\n' "$all_busy" | wc -l | tr -d ' ')" "2"

echo "== headers and untrusted body become bounded, single-line data =="
out="$(multi_check_headless "$url" fixture-key headers 2>"$TMP/reason")"
headers="$(cat "$TMP/reason")"
say "headers cannot alter the verdict" "$out" "RATE LIMITED (HTTP 429)"
for item in 'rEtRy-AfTeR: 3600' 'X-RateLimit-Remaining: 0' 'RateLimit-Reset: 42'; do
  say "retains $item" "$(contains "$headers" "$item")" "yes"
done
say "unrelated headers withheld" "$(contains "$headers" PRIVATE_COOKIE)" "no"
out="$(multi_check_headless "$url" fixture-key dirty 2>"$TMP/reason")"
dirty="$(cat "$TMP/reason")"
say "dirty body cannot alter the verdict" "$out" "RATE LIMITED (HTTP 429)"
say "no control or formatting characters survive" "$("$py" - "$dirty" <<'PY'
import sys, unicodedata
print('yes' if all(not unicodedata.category(c).startswith('C') for c in sys.argv[1]) else 'no')
PY
)" "yes"
say "Unicode reason retained" "$(contains "$dirty" Лимит)" "yes"
say "echoed key redacted" "$(contains "$dirty" fixture-key)" "no"
out="$(multi_check_headless "$url" fixture-key long 2>"$TMP/reason")"
long="$(cat "$TMP/reason")"
say "body capped at 200 characters" "$("$py" - "$long" <<'PY'
import sys
print(len(sys.argv[1].split('endpoint text (untrusted): ', 1)[1].split('; ', 1)[0]))
PY
)" "200"
say "body tail discarded" "$(contains "$long" TAIL_SENTINEL)" "no"
say "headers remain after a long body" "$(contains "$long" 'X-RateLimit-Remaining: 0')" "yes"
out="$(LC_ALL=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 PYTHONIOENCODING=ascii \
  multi_check_headless "$url" fixture-key unicode 2>"$TMP/reason")"
unicode="$(cat "$TMP/reason")"
say "UTF-8 is capped by characters, not broken bytes" "$("$py" - "$unicode" <<'PY'
import sys
print('yes' if len(sys.argv[1].split('endpoint text (untrusted): ', 1)[1]) == 200 and '\ufffd' not in sys.argv[1] else 'no')
PY
)" "yes"
say "empty diagnostics keep the old wording" "$(multi_check_headless "$url" fixture-key empty 2>"$TMP/reason")" "RATE LIMITED (HTTP 429)"
say "empty diagnostics have no reason" "$(cat "$TMP/reason")" ""
out="$(multi_check_headless "$url" fixture-key empty-retry 2>"$TMP/reason")"
say "bare retry keeps its current verdict" "$out" "RATE LIMITED (HTTP 429)"
say "bare retry drops the first reason" "$(cat "$TMP/reason")" ""
out="$(multi_check_headless "$url" fixture-key changes 2>"$TMP/reason")"
say "retry failure uses its current status" "$out" "HTTP 503"
say "retry reason comes only from the latest response" "$(contains "$(cat "$TMP/reason")" 'Upstream unavailable')$(contains "$(cat "$TMP/reason")" 'First spike')" "yesno"
say "a changed retry status stops at two requests" "$(requests changes)" "2"
for model in retry-disconnect retry-bare-503; do
  expected="HTTP 000"; [ "$model" != retry-bare-503 ] || expected="HTTP 503"
  out="$(multi_check_headless "$url" fixture-key "$model" 2>"$TMP/reason")"
  say "$model reports the retry's status" "$out" "$expected"
  say "$model cannot reuse a stale reason" "$(cat "$TMP/reason")" ""
  say "$model stops at two requests" "$(requests "$model")" "2"
done

echo "== huge and streamed bodies cannot fill TMPDIR =="
for model in huge stream; do
  out="$(multi_check_headless "$url" fixture-key "$model" 2>"$TMP/reason")"
  say "$model preserves the HTTP verdict" "$out" "RATE LIMITED (HTTP 429)"
  say "$model still retries exactly once" "$(requests "$model")" "2"
  say "$model retains the bounded prefix only" "$(contains "$(cat "$TMP/reason")" 'qqqq')$(contains "$(cat "$TMP/reason")" TAIL_SENTINEL)" "yesno"
  # 0 is legal: BSD head buffers its prefix and writes it only at exit.
  say "$model writes at most 8 KiB per capture file" "$(awk -F '\t' -v m="$model" '$1==m {n++; if ($2>8192) bad++} END {print (n==2 && !bad) ? "yes" : "no"}' "$TMP/disk-sizes")" "yes"
done

echo "== CRLF Python stdout stays a single UTF-8 diagnostic =="
export POOL_REAL_PY="$py"
cat > "$TMP/crlf-python" <<'STUB'
#!/usr/bin/env bash
set -o pipefail
"$POOL_REAL_PY" "$@" | sed $'s/$/\r/'
STUB
chmod +x "$TMP/crlf-python"
out="$(
  multi_python() { printf '%s\n' "$TMP/crlf-python"; }
  multi_check_headless "$url" fixture-key unicode-crlf 2>"$TMP/reason"
)"
say "CRLF wrapper preserves the verdict" "$out" "RATE LIMITED (HTTP 429)"
say "CRLF wrapper preserves Unicode" "$(contains "$(cat "$TMP/reason")" Лимит)" "yes"
say "CRLF wrapper leaves no carriage return" "$(contains "$(cat "$TMP/reason")" $'\r')" "no"

echo "== other HTTP errors and transport failures are not retried =="
for code in 401 403 402 404 500 503; do
  case "$code" in
    401|403) expected="BAD KEY (HTTP $code)" ;;
    402) expected="NO CREDIT (HTTP 402)" ;;
    *) expected="HTTP $code" ;;
  esac
  out="$(multi_check_headless "$url" fixture-key "error-$code")"; rc=$?
  say "HTTP $code keeps its wording" "$out" "$expected"
  say "HTTP $code remains a failure" "$rc" "1"
  say "HTTP $code is requested once" "$(requests "error-$code")" "1"
done
for model in disconnect timeout partial-timeout; do
  out="$(multi_check_headless "$url" fixture-key "$model")"; rc=$?
  expected="HTTP 000"; [ "$model" != partial-timeout ] || expected="RATE LIMITED (HTTP 429)"
  say "$model keeps its wording" "$out" "$expected"
  say "$model remains a failure" "$rc" "1"
  say "$model is not retried" "$(requests "$model")" "1"
done
out="$(multi_check_headless "$url" '' no-key)"; rc=$?
say "missing key keeps its wording" "$out" "NO KEY"
say "missing key remains a failure" "$rc" "1"
say "missing key makes no request" "$(requests no-key)" "0"

echo "== setup status labels endpoint text on one backend line =="
cat > "$MULTI_CONFIG" <<EOF
default_profile = "p"
[backends.fixture]
type = "claude-headless"
base_url = "$url"
api_key_env = "POOL_FIXTURE_KEY"
models = ["quota-setup", "spike", "ok"]
[profiles]
p = ["fixture"]
EOF
status="$(POOL_FIXTURE_KEY=fixture-key bash "$TREE/scripts/setup.sh" status)"; rc=$?
say "setup status succeeds" "$rc" "0"
backend="$(printf '%s\n' "$status" | grep '^fixture:')"
say "setup names the fallback and quota" "$(contains "$backend" 'OK — will use ok')$(contains "$backend" 'skipped before it: quota-setup (RATE LIMITED (HTTP 429))')$(contains "$backend" 'endpoint text (untrusted): {"error":{"message":"Account quota exhausted"}}')" "yesyesyes"
say "setup also names the provider spike" "$(contains "$backend" 'Provider temporarily overloaded')" "yes"
say "one backend line despite longer diagnostics" "$(printf '%s\n' "$backend" | wc -l | tr -d ' ')" "1"
sed 's/"quota-setup", "spike", "ok"/"quota-setup-busy", "spike"/' "$MULTI_CONFIG" > "$TMP/config-busy"
mv "$TMP/config-busy" "$MULTI_CONFIG"
status="$(POOL_FIXTURE_KEY=fixture-key bash "$TREE/scripts/setup.sh" status)"
backend="$(printf '%s\n' "$status" | grep '^fixture:')"
say "all-busy setup still lists the skipped models" "$(contains "$backend" 'ALL POOLS BUSY or BAD KEY')$(contains "$backend" 'skipped: quota-setup-busy (RATE LIMITED (HTTP 429))')" "yesyes"
say "all-busy setup preserves both labelled reasons" "$(contains "$backend" 'endpoint text (untrusted): {"error":{"message":"Account quota exhausted"}}')$(contains "$backend" 'endpoint text (untrusted): Provider temporarily overloaded')" "yesyes"
say "every request matched the real probe protocol" "$(awk -F '\t' '$3!="True" {bad++} END {print bad+0}' "$TMP/requests")" "0"
say "probe temp directories removed" "$(find "$TMP/probes" -mindepth 1 -print | wc -l | tr -d ' ')" "0"
say "the caller's cleanup trap survives" "$(contains "$(trap -p EXIT)" cleanup)" "yes"

echo "== mktemp failure stops the suite before any fixture writes =="
mkdir -p "$TMP/failing-bin"
export POOL_FAILED_TMP="$TMP/mktemp-must-not-be-used"
cat > "$TMP/failing-bin/mktemp" <<'STUB'
#!/usr/bin/env bash
# A path plus failure keeps this regression safe even if the guard is removed.
printf '%s\n' "$POOL_FAILED_TMP"
exit 1
STUB
chmod +x "$TMP/failing-bin/mktemp"
out="$(PATH="$TMP/failing-bin:$PATH" bash "$TREE/scripts/test-pool-probe.sh" 2>&1)"; rc=$?
say "mktemp failure exits nonzero" "$rc" "1"
say "mktemp failure is explicit" "$out" "FAIL: mktemp failed"
say "no fixture directory is created after mktemp failure" "$([ ! -e "$POOL_FAILED_TMP" ] && echo yes || echo no)" "yes"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
