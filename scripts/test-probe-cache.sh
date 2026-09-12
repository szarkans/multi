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
unset MULTI_OPENCODE_CANDIDATES MULTI_PROBE_CACHE_MIN
export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/h" MARKER="$TMP/calls"
mkdir -p "$MULTI_HOME"
CONFIG="$MULTI_HOME/config.toml"
oc_config() { # oc_config '"a", "b"' -> a config whose opencode backend lists those models
  printf 'default_profile = "p"\n[backends.opencode]\ntype = "opencode"\nmodels = [%s]\n[profiles]\np = ["opencode"]\n' "$1" > "$CONFIG"
}
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
oc_config '"opencode-go/glm-5.3-flash", "opencode-go/deepseek-v4-flash"'
rm -f "$MULTI_HOME/opencode-models.cache"
: > "$MARKER"
configured="$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep '^opencode:')"
say "primary and fallback are used in order" "$configured" "opencode: OK — opencode-go/glm-5.3-flash (fallback: opencode-go/deepseek-v4-flash) (from config)"
say "config bypasses model catalogue" "$(grep -c CALLED "$MARKER")" "0"

echo "== an empty models list falls through to auto-detection =="
oc_config ''
rm -f "$MULTI_HOME/opencode-models.cache"
: > "$MARKER"
commas_only="$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep '^opencode:')"
say "empty list uses auto-detection" "$commas_only" "opencode: OK — opencode/deepseek-v4-flash-free (fallback: opencode/other-free)"
say "empty list reads the catalogue" "$(grep -c CALLED "$MARKER")" "1"

rm -f "$CONFIG"
automatic="$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep '^opencode:')"
say "missing config restores auto-detection" "$automatic" "opencode: OK — opencode/deepseek-v4-flash-free (fallback: opencode/other-free)"
say "auto-detection reads the catalogue" "$(grep -c CALLED "$MARKER")" "1"

echo "== the pre-config models file is reported, not read =="
printf 'opencode: opencode-go/old-list\n' > "$MULTI_HOME/models"
legacy="$(bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "legacy line printed" "$(grep -c '^models-config: LEGACY' <<<"$legacy")" "1"
say "its list is not used" "$(grep -c 'old-list' <<<"$(grep '^opencode:' <<<"$legacy")")" "0"
rm -f "$MULTI_HOME/models"

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

echo "== 1.15 config dir: XDG by default, one notice for the pre-1.15 place, no migration =="
# A fake HOME so the machine's real ~/.claude/multi and ~/.config/multi stay out of it.
FH="$TMP/fakehome"; mkdir -p "$FH/.claude/multi"
printf 'default_profile="p"\n[backends.codex]\ntype="codex"\n[profiles]\np=["codex"]\n' > "$FH/.claude/multi/config.toml"   # valid, but the probe must not read it
py="$(command -v python3 || command -v python)"
say "default config path is ~/.config/multi" "$(env -u MULTI_HOME -u XDG_CONFIG_HOME HOME="$FH" "$py" "$TREE/scripts/config.py" path)" "$FH/.config/multi/config.toml"
say "XDG_CONFIG_HOME is honoured" "$(env -u MULTI_HOME HOME="$FH" XDG_CONFIG_HOME="$FH/xdg" "$py" "$TREE/scripts/config.py" path)" "$FH/xdg/multi/config.toml"
out="$(env -u MULTI_HOME -u XDG_CONFIG_HOME HOME="$FH" bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "old dir with files: exactly one notice" "$(printf '%s\n' "$out" | grep -c '^config-dir: LEGACY')" "1"
say "notice names the old and the new place" "$(printf '%s\n' "$out" | grep -c "LEGACY — $FH/.claude/multi is no longer read.*$FH/.config/multi")" "1"
say "old config is not read (probe reports the built-in default)" "$(printf '%s\n' "$out" | grep -c '^config: built-in default')" "1"
say "nothing was moved" "$([ -e "$FH/.config/multi/config.toml" ] && echo moved || echo no)" "no"
# The old config may have pointed the key at another host; with the key set and
# only the old file present, nothing may run (the built-in default would use
# openrouter.ai).
out="$(env -u MULTI_HOME -u XDG_CONFIG_HOME HOME="$FH" OPENROUTER_API_KEY=sk-test bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "old config + key in env: hard stop" "$(printf '%s\n' "$out" | grep -c '^config: BROKEN.*OPENROUTER_API_KEY is set')" "1"
out="$(env -u MULTI_HOME -u XDG_CONFIG_HOME HOME="$FH" OPENROUTER_API_KEY=sk-test MULTI_CONFIG="$FH/.claude/multi/config.toml" bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "MULTI_CONFIG at the old file: no stop, no notice" "$(printf '%s\n' "$out" | grep -c '^config: BROKEN\|^config-dir: LEGACY')" "0"
# An override that names only the keys file does not make the old config read:
# the notice stays, and so does the stop (found by the 1.15.0 review round).
printf "export OPENROUTER_API_KEY='sk-from-file'\n" > "$FH/keys.env"
out="$(env -u MULTI_HOME -u XDG_CONFIG_HOME -u OPENROUTER_API_KEY HOME="$FH" MULTI_PROVIDERS_ENV="$FH/keys.env" bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "MULTI_PROVIDERS_ENV elsewhere + old config: hard stop" "$(printf '%s\n' "$out" | grep -c '^config: BROKEN.*OPENROUTER_API_KEY is set')" "1"
say "  and the old-config notice stays" "$(printf '%s\n' "$out" | grep -c '^config-dir: LEGACY')" "1"
out="$(env -u XDG_CONFIG_HOME HOME="$FH" MULTI_HOME="$FH/.claude/multi" bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "hand-set MULTI_HOME to the old place: no notice" "$(printf '%s\n' "$out" | grep -c '^config-dir: LEGACY')" "0"
rm -rf "$FH/.claude/multi"
out="$(env -u MULTI_HOME -u XDG_CONFIG_HOME HOME="$FH" bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "no old dir: no notice" "$(printf '%s\n' "$out" | grep -c '^config-dir: LEGACY')" "0"

echo "== update notice: once per new version, from the CHANGELOG, never on first run =="
VER="$(sed -n '/"version"/{s/.*"version": *"\([^"]*\)".*/\1/p;q;}' "$TREE/.claude-plugin/plugin.json")"
rm -f "$MULTI_HOME/.seen-version"
out="$(bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "first run: no notice" "$(printf '%s\n' "$out" | grep -c '^update: multi')" "0"
say "first run: version recorded" "$(cat "$MULTI_HOME/.seen-version")" "$VER"
printf '0.0.1\n' > "$MULTI_HOME/.seen-version"
out="$(bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "older seen: one notice" "$(printf '%s\n' "$out" | grep -c "^update: multi $VER (you last ran 0.0.1)")" "1"
say "notice carries this version's CHANGELOG bullets" "$(printf '%s\n' "$out" | grep -c '^  - ')" "$(awk -v v="## $VER" 'index($0, v)==1 {on=1; next} /^## /{on=0} on && /^- /' "$TREE/CHANGELOG.md" | wc -l | tr -d ' ')"
say "seen updated" "$(cat "$MULTI_HOME/.seen-version")" "$VER"
out="$(bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "second run: silent" "$(printf '%s\n' "$out" | grep -c '^update: multi')" "0"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
