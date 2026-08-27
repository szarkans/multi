#!/usr/bin/env bash
# Checks --backend routing in ask.sh: the flag must actually skip a backend,
# not just relabel the output. Uses stub codex/opencode on PATH, so it needs
# no network, no API keys and no real CLI installed.
#
#   bash scripts/test-ask-backend.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""; model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -m) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && { echo "CODEX ANSWER"; [ -n "$model" ] && echo "MODEL=$model"; } > "$out"
STUB
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "OPENCODE ANSWER"
STUB
chmod +x "$TMP/bin/codex" "$TMP/bin/opencode"
export PATH="$TMP/bin:$PATH"

fail=0
check() { # name expect_codex expect_opencode
  local n="$1" ec="$2" eo="$3" p="$TMP/$1"
  local gc=no go=no
  [ -f "$p-codex.txt" ] && gc=yes
  [ -f "$p-opencode.txt" ] && go=yes
  if [ "$gc" = "$ec" ] && [ "$go" = "$eo" ]; then
    echo "ok   $n (codex=$gc opencode=$go)"
  else
    echo "FAIL $n: expected codex=$ec opencode=$eo, got codex=$gc opencode=$go"; fail=1
  fi
}

"$HERE/ask.sh" --question q --out-prefix "$TMP/both"  --model m >/dev/null
check both yes yes
"$HERE/ask.sh" --question q --out-prefix "$TMP/only-cx" --model m --backend codex >/dev/null
check only-cx yes no
"$HERE/ask.sh" --question q --out-prefix "$TMP/only-oc" --model m --backend opencode >/dev/null
check only-oc no yes

# A typo in the backend name must stop the run, not silently fall through to both.
"$HERE/ask.sh" --question q --out-prefix "$TMP/bogus" --model m --backend gpt >/dev/null 2>&1
[ $? -eq 2 ] && echo "ok   bad backend rejected" || { echo "FAIL bad backend not rejected"; fail=1; }

# Both files must carry the answer, not an empty file that reads as one.
grep -q "CODEX ANSWER" "$TMP/both-codex.txt" || { echo "FAIL codex answer not written"; fail=1; }
grep -q "OPENCODE ANSWER" "$TMP/both-opencode.txt" || { echo "FAIL opencode answer not written"; fail=1; }

# name:model syntax, split on the FIRST colon only — the model itself carries
# a colon (free-tier suffix style), which must survive intact.
"$HERE/ask.sh" --question q --out-prefix "$TMP/colon" --backend "codex:foo/bar:free" >/dev/null
grep -q "MODEL=foo/bar:free" "$TMP/colon-codex.txt" || { echo "FAIL colon-model not passed through"; fail=1; }

# Two entries for the same backend must not collide: first keeps the plain
# name, the second gets -2, each carrying its own model.
"$HERE/ask.sh" --question q --out-prefix "$TMP/dup" --backend "codex:model-a,codex:model-b" >/dev/null
if [ -f "$TMP/dup-codex.txt" ] && [ -f "$TMP/dup-codex-2.txt" ] \
  && grep -q "MODEL=model-a" "$TMP/dup-codex.txt" && grep -q "MODEL=model-b" "$TMP/dup-codex-2.txt"; then
  echo "ok   duplicate backend gets -2 suffix"
else
  echo "FAIL duplicate backend did not produce distinct -codex.txt / -codex-2.txt"; fail=1
fi

# Old --codex-model flag must still set the model for a bare (no-colon) entry.
"$HERE/ask.sh" --question q --out-prefix "$TMP/oldflag" --backend codex --codex-model old-style-model >/dev/null
grep -q "MODEL=old-style-model" "$TMP/oldflag-codex.txt" || { echo "FAIL --codex-model alias broken"; fail=1; }

# A model whose answer starts with the backend's own failure words is alive:
# ask.sh used to grep the answer text for "codex: NO OUTPUT" and read a real
# answer as a dead backend. Alive = file with content and no .dead sidecar.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""; model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -m) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && { echo "codex: NO OUTPUT was observed in the legacy module"; [ -n "$model" ] && echo "MODEL=$model"; } > "$out"
STUB
chmod +x "$TMP/bin/codex"
"$HERE/ask.sh" --question q --out-prefix "$TMP/alive" --model m --backend codex >/dev/null
if grep -q "codex: NO OUTPUT was observed" "$TMP/alive-codex.txt" && [ ! -e "$TMP/alive-codex.txt.dead" ]; then
  echo "ok   answer starting with failure words counts as alive"
else
  echo "FAIL a live answer was misread as a dead backend"; fail=1
fi

# The RAW CAPTURE path (an opencode that does not speak --format json) is a
# live backend: the answer is unstructured, not absent — no .dead marker, and
# ask.sh must not report "no backend alive".
"$HERE/ask.sh" --question q --out-prefix "$TMP/rawcap" --model m --backend opencode >/dev/null
rc=$?
if [ $rc -eq 0 ] && grep -q "RAW CAPTURE ONLY" "$TMP/rawcap-opencode.txt" && [ ! -e "$TMP/rawcap-opencode.txt.dead" ]; then
  echo "ok   raw capture counts as alive"
else
  echo "FAIL raw capture read as dead (exit $rc)"; fail=1
fi

# A stale .dead sidecar from a failed run must not condemn the next run with
# the same out-prefix: the marker describes one invocation, not the file.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
exit 0   # writes nothing: a silent failure
STUB
chmod +x "$TMP/bin/codex"
"$HERE/ask.sh" --question q --out-prefix "$TMP/stale" --model m --backend codex >/dev/null
[ -e "$TMP/stale-codex.txt.dead" ] || { echo "FAIL failed run did not leave a marker"; fail=1; }
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && echo "SECOND RUN ANSWER" > "$out"
STUB
chmod +x "$TMP/bin/codex"
"$HERE/ask.sh" --question q --out-prefix "$TMP/stale" --model m --backend codex >/dev/null
rc=$?
if [ $rc -eq 0 ] && grep -q "SECOND RUN ANSWER" "$TMP/stale-codex.txt" && [ ! -e "$TMP/stale-codex.txt.dead" ]; then
  echo "ok   stale marker does not condemn the next run"
else
  echo "FAIL stale marker condemned a live run (exit $rc)"; fail=1
fi

# Gemini stderr is diagnostics, not an answer. A failed CLI must keep it in the
# durable dead log after the trusted reason replaces the empty answer file.
cat > "$TMP/bin/gemini" <<'STUB'
#!/usr/bin/env bash
echo "GEMINI DIAGNOSTIC XYZZY" >&2
exit 7
STUB
chmod +x "$TMP/bin/gemini"
GEMINI_API_KEY=test "$HERE/ask.sh" --question q --out-prefix "$TMP/gemini-fail" --backend gemini >/dev/null 2>&1
if [ -s "$TMP/gemini-fail-gemini.txt.dead" ] \
  && grep -q 'GEMINI DIAGNOSTIC XYZZY' "$TMP/gemini-fail-gemini.txt.dead.log"; then
  echo "ok   gemini failure keeps stderr in dead log"
else
  echo "FAIL gemini failure lost stderr diagnostics"; fail=1
fi

# Partial stdout from a failed Gemini process is not a trustworthy answer. It
# must be replaced by a dead reason, with stderr retained for diagnosis, and
# the single-backend run must report that no backend answered.
cat > "$TMP/bin/gemini" <<'STUB'
#!/usr/bin/env bash
echo "PARTIAL GEMINI ANSWER"
echo "GEMINI PARTIAL FAILURE XYZZY" >&2
exit 7
STUB
chmod +x "$TMP/bin/gemini"
GEMINI_API_KEY=test "$HERE/ask.sh" --question q --out-prefix "$TMP/gemini-partial" --backend gemini >/dev/null 2>&1
gemini_partial_rc=$?
if [ "$gemini_partial_rc" -ne 0 ] \
  && [ -s "$TMP/gemini-partial-gemini.txt.dead" ] \
  && grep -q 'GEMINI PARTIAL FAILURE XYZZY' "$TMP/gemini-partial-gemini.txt.dead.log" \
  && ! grep -q 'PARTIAL GEMINI ANSWER' "$TMP/gemini-partial-gemini.txt"; then
  echo "ok   failed gemini partial output is dead, logged, and not counted alive"
else
  echo "FAIL failed gemini partial output counted alive or lost diagnostics (exit $gemini_partial_rc)"; fail=1
fi

# Observe the timeout at the process boundary. GNU timeout receives
# `-k GRACE SECONDS COMMAND ...`; the stub records the resolved value and then
# runs the fast fake backend normally.
cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "$3" "$4" >> "$MULTI_TIMEOUT_TRACE"
shift 3
"$@"
STUB
chmod +x "$TMP/bin/timeout"
: > "$TMP/timeouts"
MULTI_TIMEOUT_TRACE="$TMP/timeouts" MULTI_CODEX_TIMEOUT=17 MULTI_BACKEND_TIMEOUT=9 \
  "$HERE/ask.sh" --question q --out-prefix "$TMP/timeouts-explicit" --backend codex,opencode --model m >/dev/null
codex_timeout_count="$(grep -c $'^17\tcodex$' "$TMP/timeouts")"
opencode_timeout_count="$(grep -c $'^9\topencode$' "$TMP/timeouts")"
if [ "$codex_timeout_count" -eq 1 ] && [ "$opencode_timeout_count" -eq 1 ]; then
  echo "ok   codex timeout knob overrides only codex (codex=17 opencode=9)"
else
  echo "FAIL timeout split not applied (codex=$codex_timeout_count opencode=$opencode_timeout_count)"; fail=1
fi

: > "$TMP/default-timeout"
( unset MULTI_CODEX_TIMEOUT
  MULTI_TIMEOUT_TRACE="$TMP/default-timeout" MULTI_BACKEND_TIMEOUT=9 \
    "$HERE/ask.sh" --question q --out-prefix "$TMP/timeouts-default" --backend codex >/dev/null
)
if [ "$(grep -c $'^600\tcodex$' "$TMP/default-timeout")" -eq 1 ]; then
  echo "ok   codex keeps its 600s default above a shorter shared timeout"
else
  echo "FAIL shorter shared timeout replaced codex 600s default"; fail=1
fi

: > "$TMP/review-timeout"
( unset MULTI_CODEX_TIMEOUT MULTI_BACKEND_TIMEOUT
  MULTI_TIMEOUT_TRACE="$TMP/review-timeout" "$HERE/ask.sh" --question q \
    --out-prefix "$TMP/timeouts-review" --backend codex --timeout 901 >/dev/null
)
if [ "$(grep -c $'^901\tcodex$' "$TMP/review-timeout")" -eq 1 ]; then
  echo "ok   shared review timeout raises default codex timeout"
else
  echo "FAIL review --timeout did not govern default codex timeout"; fail=1
fi

# The opencode reviewer must stay read-only. Every real `opencode run` in ask.sh
# must carry --agent plan and must NEVER carry --auto: --auto pre-approves write
# and bash, which is the P4 hole (full read+write+exec in the live tree). The
# stubs above ignore flags, so only this source guard catches a silent revert --
# a regression test for exactly the flag whose measurement lives in a comment.
# Herestrings, not pipes: `grep -q` in a pipe dies of SIGPIPE under pipefail.
oc_cmds="$(grep -nE 'multi_timeout .*opencode run' "$HERE/ask.sh")"
n_cmds="$(grep -c 'opencode run' <<<"$oc_cmds")"
n_plan="$(grep -c -- '--agent plan' <<<"$oc_cmds")"
if [ "$n_cmds" -ge 1 ] && ! grep -q -- '--auto' <<<"$oc_cmds" && [ "$n_plan" -eq "$n_cmds" ]; then
  echo "ok   opencode stays read-only (--agent plan, no --auto) on all $n_cmds invocation(s)"
else
  echo "FAIL opencode not read-only: every 'opencode run' in ask.sh needs --agent plan and no --auto (found $n_cmds cmd(s), $n_plan with plan)"; fail=1
fi

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
