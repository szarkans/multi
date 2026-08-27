#!/usr/bin/env bash
# probe.sh runs before every skill invocation, and `opencode models` was its
# whole cost: 2.9s against 49ms for the codex check (measured 2026-08-20).
# The list is cached, so this checks the cache is actually used, does not
# change the answer, and can be switched off.
#
#   bash scripts/test-probe-cache.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "CALLED" >> "$MARKER"
echo "opencode/deepseek-v4-flash-free"
echo "opencode/other-free"
STUB
printf '#!/usr/bin/env bash\necho "Logged in using ChatGPT"\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/"*
unset MULTI_OPENCODE_MODEL MULTI_OPENCODE_CANDIDATES MULTI_PROBE_CACHE_MIN
export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/h" MARKER="$TMP/calls" \
  MULTI_MODELS_CONFIG="$TMP/models"
: > "$MARKER"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

a="$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep '^opencode:')"
b="$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep '^opencode:')"
say "same answer both runs" "$a" "$b"
say "opencode models called once, not twice" "$(grep -c CALLED "$MARKER")" "1"

: > "$MARKER"
MULTI_PROBE_CACHE_MIN=0 bash "$TREE/scripts/probe.sh" >/dev/null 2>&1
say "cache can be turned off" "$(grep -c CALLED "$MARKER")" "1"

echo "== a configured model list overrides auto-detection =="
printf '%s\n' 'opencode: opencode-go/glm-5.3-flash, opencode-go/deepseek-v4-flash' > "$MULTI_MODELS_CONFIG"
rm -f "$MULTI_HOME/opencode-models.cache"
: > "$MARKER"
configured="$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep '^opencode:')"
say "comma-separated primary and fallback are used" "$configured" "opencode: OK — opencode-go/glm-5.3-flash (fallback: opencode-go/deepseek-v4-flash) (from config)"
say "config bypasses model catalogue" "$(grep -c CALLED "$MARKER")" "0"

rm -f "$MULTI_MODELS_CONFIG"
automatic="$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep '^opencode:')"
say "missing config restores auto-detection" "$automatic" "opencode: OK — opencode/deepseek-v4-flash-free (fallback: opencode/other-free)"
say "auto-detection reads the catalogue" "$(grep -c CALLED "$MARKER")" "1"

echo "== a listing that failed halfway is not cached =="
rm -f "$MULTI_HOME/opencode-models.cache"
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
echo "opencode/deepseek-v4-flash-free"
exit 1
STUB
chmod +x "$TMP/bin/opencode"
bash "$TREE/scripts/probe.sh" >/dev/null 2>&1
say "no cache written from a failed run" "$([ -e "$MULTI_HOME/opencode-models.cache" ] && echo yes || echo no)" "no"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
