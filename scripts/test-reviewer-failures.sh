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
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$TMP/bin/$n"; chmod +x "$TMP/bin/$n"
done
export PATH="$TMP/bin:$PATH"
export MULTI_HOME="$TMP/home"; mkdir -p "$MULTI_HOME"
export MULTI_BACKEND_TIMEOUT=3 MULTI_REVIEW_TIMEOUT=3
echo "bash $BASH_VERSION | timeout: $(command -v timeout || echo none)"

fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1 ($2)"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

echo "== ask.sh with both CLIs hung =="
s=$SECONDS
bash "$TREE/scripts/ask.sh" --question q --backend both --model m --out-prefix "$TMP/a" >/dev/null 2>&1
d=$((SECONDS-s))
say "returns fast (<=10s)" "$([ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
say "codex file non-empty" "$([ -s "$TMP/a-codex.txt" ] && echo yes || echo no)" "yes"
echo "   codex says:    $(head -1 "$TMP/a-codex.txt" 2>/dev/null)"
echo "   opencode says: $(head -1 "$TMP/a-opencode.txt" 2>/dev/null)"
say "codex marked TIMEOUT" "$(grep -qi 'TIMEOUT' "$TMP/a-codex.txt" && echo yes || echo no)" "yes"
say "opencode marked TIMEOUT" "$(grep -qi 'TIMEOUT' "$TMP/a-opencode.txt" && echo yes || echo no)" "yes"

echo "== review-codex.sh with codex hung =="
s=$SECONDS
bash "$TREE/scripts/review-codex.sh" --target t --out "$TMP/rc.txt" >/dev/null 2>&1
d=$((SECONDS-s))
say "returns fast" "$([ $d -le 10 ] && echo yes || echo "no(${d}s)")" "yes"
echo "   says: $(head -1 "$TMP/rc.txt" 2>/dev/null)"
say "not empty" "$([ -s "$TMP/rc.txt" ] && echo yes || echo no)" "yes"
say "says TIMEOUT" "$(grep -qi 'TIMEOUT' "$TMP/rc.txt" && echo yes || echo no)" "yes"

echo "== review-opencode.sh with opencode hung =="
s=$SECONDS
bash "$TREE/scripts/review-opencode.sh" --target t --model m --out "$TMP/ro.txt" >/dev/null 2>&1
d=$((SECONDS-s))
say "returns fast" "$([ $d -le 15 ] && echo yes || echo "no(${d}s)")" "yes"
echo "   says: $(head -1 "$TMP/ro.txt" 2>/dev/null)"
say "not empty" "$([ -s "$TMP/ro.txt" ] && echo yes || echo no)" "yes"
say "says TIMEOUT" "$(grep -qi 'TIMEOUT' "$TMP/ro.txt" && echo yes || echo no)" "yes"

echo "== an opencode too old for --format json still reaches the judge =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
printf '\033[32m> build - deepseek\033[0m\n'
echo "I looked at the diff. The retry loop in worker.py can spin forever when"
echo "the queue is empty, and nobody resets the counter."
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/review-opencode.sh" --target t --model m --out "$TMP/off.txt" >/dev/null 2>&1
say "labelled as a raw capture" "$(grep -q 'RAW CAPTURE ONLY' "$TMP/off.txt" && echo yes || echo no)" "yes"
say "the answer survived" "$(grep -q 'retry loop in worker.py' "$TMP/off.txt" && echo yes || echo no)" "yes"
say "quoted lines cannot pass as findings" "$(grep -cE '^[^|]*:[0-9]+[^|]*\| *(HIGH|MEDIUM|LOW) *\|' "$TMP/off.txt")" "0"
say "ANSI stripped" "$(LC_ALL=C grep -q "$(printf '\033')" "$TMP/off.txt" && echo no || echo yes)" "yes"

echo "== a hang that printed a header is not an answer =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "> build - deepseek"   # opencode prints this within a second
sleep 300
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/p" >/dev/null 2>&1
rcode=$?
say "partial transcript marked TIMEOUT" "$(grep -c 'TIMEOUT' "$TMP/p-opencode.txt")" "1"
say "not counted as a live backend" "$rcode" "1"


echo "== a CLI that ignores SIGTERM is still killed =="
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
trap '' TERM
sleep 300
STUB
chmod +x "$TMP/bin/opencode"
s=$SECONDS
MULTI_TIMEOUT_GRACE=3 bash "$TREE/scripts/ask.sh" --question q --backend opencode --model m --out-prefix "$TMP/k" >/dev/null 2>&1
d=$((SECONDS-s))
say "killed within grace" "$([ $d -le 15 ] && echo yes || echo "no(${d}s)")" "yes"
say "reported as a timeout" "$(grep -c 'TIMEOUT' "$TMP/k-opencode.txt")" "1"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
