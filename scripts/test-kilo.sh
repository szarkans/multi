#!/usr/bin/env bash
# The kilo backend: Kilo Code CLI (an OpenCode fork) run through the opencode
# runner. A stub `kilo` on PATH, no network, no real CLI. What matters most:
# read-only depends ENTIRELY on the config handed over in KILO_CONFIG_CONTENT
# and on --agent multi-readonly -- without them kilo writes files happily
# (measured live 2026-10-04) -- so this test reads both back from the stub.
#
#   bash scripts/test-kilo.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/h"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

cat > "$TMP/bin/kilo" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--pure" ] && [ "${2:-}" = "models" ]; then
  printf '%s\n' kilo/kilo-auto/free kilo/openrouter/free kilo/nvidia/nemotron-3-super-120b-a12b:free \
    kilo/qwen/qwen3.8-27b:free kilo/other/x:free kilo/paid/y
  exit 0
fi
printf '%s\n' "$@" > "$KILO_TEST_DIR/argv"
printf '%s' "${KILO_CONFIG_CONTENT:-}" > "$KILO_TEST_DIR/config"
printf '%s' "${KILO_DISABLE_PROJECT_CONFIG:-}" > "$KILO_TEST_DIR/noproj"
case "${MODE:-ok}" in
  silent) sleep 30 ;;
  *) echo '{"type":"step_start","timestamp":1000,"part":{}}'
     echo '{"type":"text","timestamp":1600,"part":{"text":"a.py:1 | HIGH | kilo finding"}}' ;;
esac
STUB
chmod +x "$TMP/bin/kilo"
# No network, ever: the training catalogue comes from a fixture, and a curl on
# PATH only records that someone tried (asserted at the end).
printf '{"data":[{"id":"qwen/qwen3.8-27b:free","mayTrainOnYourPrompts":true}]}\n' > "$TMP/models.json"
printf '#!/usr/bin/env bash\necho "$*" >> "$KILO_TEST_DIR/curl-called"\nexit 7\n' > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"
export KILO_TEST_DIR="$TMP" MULTI_HOME="$TMP/h" PATH="$TMP/bin:$PATH" MULTI_KILO_TRAINING_FIXTURE="$TMP/models.json"
# kilo is not in the built-in config, so the run tests bring their own.
printf 'default_profile = "p"\n[backends.kilo]\ntype = "kilo"\nmodels = []\n[profiles]\np = ["kilo"]\n' > "$TMP/kcfg.toml"
export MULTI_CONFIG="$TMP/kcfg.toml"
mkdir -p "$TMP/repo"; ( cd "$TMP/repo" && git init -q . && echo x > a.py && git add . ) >/dev/null 2>&1

echo "== a kilo run: answer lands, read-only guarantee is in the invocation =="
bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r1" --backend kilo:kilo/qwen/qwen3.8-27b:free --repo "$TMP/repo" >/dev/null 2>&1
say "answer written" "$(grep -c 'kilo finding' "$TMP/r1-kilo.txt" 2>/dev/null)" "1"
say "no dead marker" "$([ -e "$TMP/r1-kilo.txt.dead" ] && echo dead || echo alive)" "alive"
args="$(tr '\n' ' ' < "$TMP/argv")"
case "$args" in "run --pure --agent multi-readonly --format json -m kilo/qwen/qwen3.8-27b:free "*) r=ok ;; *) r="$args" ;; esac
say "run --pure --agent multi-readonly --format json -m <model>" "$r" ok
case "$args" in *--auto*) r=has-auto ;; *) r=none ;; esac
say "never --auto" "$r" none
say "KILO_DISABLE_PROJECT_CONFIG=1" "$(cat "$TMP/noproj")" "1"
say "KILO_CONFIG_CONTENT is the read-only agent config" "$(python3 -c '
import json,sys
p=json.load(open(sys.argv[1]))["agent"]["multi-readonly"]["permission"]
print(p.get("edit"), p["bash"].get("*"))' "$TMP/config")" "deny deny"
say "  and equals opencode-readonly.json plus small_model" "$(python3 -c '
import json,sys
c=json.load(open(sys.argv[1])); c.pop("small_model", None)
print(json.load(open(sys.argv[2]))==c)' "$TMP/config" "$TREE/scripts/opencode-readonly.json")" "True"
say "small_model is the model in use (-m)" "$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1]))["small_model"])' "$TMP/config")" "kilo/qwen/qwen3.8-27b:free"

echo "== --read-dir reaches kilo too =="
bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r2" --backend kilo:kilo/qwen/qwen3.8-27b:free --repo "$TMP/repo" --read-dir "$TMP/repo" >/dev/null 2>&1
say "external_directory rule in KILO_CONFIG_CONTENT" "$(grep -c external_directory "$TMP/config")" "1"

echo "== autodetect: free ids only, routers never, candidates ordered =="
. "$TREE/scripts/providers.sh"
rm -f "$MULTI_HOME"/*.cache
say "picks the first listed candidate, fallbacks = other :free in catalogue order" \
  "$(multi_opencode_autodetect kilo)" "kilo/qwen/qwen3.8-27b:free kilo/nvidia/nemotron-3-super-120b-a12b:free,kilo/other/x:free"
say "separate cache file per binary" "$([ -s "$MULTI_HOME/kilo-models.cache" ] && [ ! -e "$MULTI_HOME/opencode-models.cache" ] && echo y || echo n)" "y"
say "empty-model run picks the free model" \
  "$(bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r3" --backend kilo --repo "$TMP/repo" >/dev/null 2>&1; sed -n 's/^## \([^ ]*\) .*/\1/p;q' "$TMP/r3-kilo.txt")" "kilo/qwen/qwen3.8-27b:free"

echo "== failures name kilo, not opencode =="
printf '%s\n' kilo/kilo-auto/free kilo/openrouter/free > "$TMP/only-routers"
cat > "$TMP/bin2-kilo" <<'STUB'
#!/usr/bin/env bash
[ "${2:-}" = models ] && { cat "$KILO_TEST_DIR/only-routers"; exit 0; }
STUB
mkdir -p "$TMP/b2"; cp "$TMP/bin2-kilo" "$TMP/b2/kilo"; chmod +x "$TMP/b2/kilo"; rm -f "$MULTI_HOME"/*.cache
( PATH="$TMP/b2:$PATH"; bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r4" --backend kilo --repo "$TMP/repo" >/dev/null 2>&1 )
say "only routers listed -> NO MODEL (a router is never auto-picked)" "$(head -1 "$TMP/r4-kilo.txt" | cut -c1-14)" "kilo: NO MODEL"
say "  names kilo models" "$(grep -c '`kilo models`' "$TMP/r4-kilo.txt")" "1"
( PATH="/usr/bin:/bin"; bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r5" --backend kilo:m --repo "$TMP/repo" >/dev/null 2>&1 )
say "no kilo binary -> kilo: MISSING" "$(head -1 "$TMP/r5-kilo.txt")" "kilo: MISSING"
say "  and marked dead" "$([ -e "$TMP/r5-kilo.txt.dead" ] && echo dead || echo alive)" "dead"
printf 'default_profile = "p"\n[backends.kilo]\ntype = "kilo"\nmodels = []\nstall = 2\ntimeout = 20\n[profiles]\np = ["kilo"]\n' > "$TMP/kstall.toml"
MODE=silent MULTI_CONFIG="$TMP/kstall.toml" bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r6" --backend kilo:m --repo "$TMP/repo" >/dev/null 2>&1
say "silent kilo is killed by the stall detector" "$(head -1 "$TMP/r6-kilo.txt" | cut -c1-12)" "kilo: SILENT"

unset MULTI_CONFIG
echo "== config: type kilo is valid, but the built-in config has no kilo backend =="
say "no kilo backend in the built-in config" "$(python3 "$TREE/scripts/config.py" backends | cut -f2 | grep -c '^kilo$')" "0"
say "default profile does not run kilo" "$(python3 "$TREE/scripts/config.py" resolve | cut -f2 | tr '\n' ' ')" "codex opencode openrouter "
say "a kilo chain is accepted (walked like opencode's)" "$(printf 'default_profile = "p"\n[backends.k]\ntype = "kilo"\nmodels = ["a","b"]\nstall = 5\n[profiles]\np = ["k"]\n' > "$TMP/k.toml"; MULTI_CONFIG="$TMP/k.toml" python3 "$TREE/scripts/config.py" resolve --backend p | cut -f5)" "a b"
say "base_url on kilo is refused" "$(printf 'default_profile = "p"\n[backends.k]\ntype = "kilo"\nbase_url = "https://x.y"\n[profiles]\np = ["k"]\n' > "$TMP/k2.toml"; MULTI_CONFIG="$TMP/k2.toml" python3 "$TREE/scripts/config.py" check >/dev/null 2>&1; echo $?)" "2"

echo "== probe: built-in config + kilo on PATH -> hint, no MISSING =="
rm -f "$TMP/h/config.toml" "$MULTI_HOME"/*.cache
po="$(bash "$TREE/scripts/probe.sh" 2>/dev/null)"
say "kilo-available hint printed" "$(printf '%s\n' "$po" | grep -c '^kilo-available:')" "1"
say "no 'kilo: MISSING'" "$(printf '%s\n' "$po" | grep -c '^kilo: MISSING')" "0"

echo "== models listing: neutral cwd, project config off =="
cat > "$TMP/b3-kilo" <<'STUB'
#!/usr/bin/env bash
pwd > "$KILO_TEST_DIR/lscwd"; printf '%s' "${KILO_DISABLE_PROJECT_CONFIG:-}${OPENCODE_DISABLE_PROJECT_CONFIG:-}" > "$KILO_TEST_DIR/lsenv"
echo kilo/a/b:free
STUB
mkdir -p "$TMP/b3"; cp "$TMP/b3-kilo" "$TMP/b3/kilo"; chmod +x "$TMP/b3/kilo"; rm -f "$MULTI_HOME"/*.cache
( cd "$TMP/repo" && PATH="$TMP/b3:$PATH" multi_opencode_catalogue kilo >/dev/null )
say "both DISABLE_PROJECT_CONFIG set during models" "$(cat "$TMP/lsenv")" "11"
say "cwd is not the reviewed repo" "$([ "$(cat "$TMP/lscwd")" = "$(cd "$TMP/repo" && pwd)" ] && echo repo || echo neutral)" "neutral"

echo "== --model/--fallback are opencode-only =="
MULTI_CONFIG="$TMP/kcfg.toml" bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/r7" --backend kilo --model opencode/x --repo "$TMP/repo" >/dev/null 2>&1
case "$(tr '\n' ' ' < "$TMP/argv")" in *"-m opencode/x"*) r=got-it ;; *) r=ignored ;; esac
say "--backend kilo --model opencode/x: kilo is not handed it" "$r" ignored

echo "== probe: kilo line =="
printf 'default_profile = "p"\n[backends.kilo]\ntype = "kilo"\nmodels = []\n[profiles]\np = ["kilo"]\n' > "$TMP/h/config.toml"; rm -f "$MULTI_HOME"/*.cache
say "probe picks a free kilo model" "$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep '^kilo:')" "kilo: OK — kilo/qwen/qwen3.8-27b:free (fallback: kilo/nvidia/nemotron-3-super-120b-a12b:free,kilo/other/x:free)"
printf 'default_profile = "p"\n[backends.opencode]\ntype = "opencode"\nmodels = ["x"]\n[profiles]\np = ["opencode"]\n' > "$TMP/h/config.toml"
say "kilo installed but unconfigured is announced for setup" "$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep -c '^kilo-available:')" "1"

say "nothing in this suite touched the network" "$([ -e "$TMP/curl-called" ] && cat "$TMP/curl-called" || echo none)" none

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
