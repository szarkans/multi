#!/usr/bin/env bash
# Training verdicts, actual answering models, filtering and cache integrity.
# Every CLI and curl is a stub; fixtures bypass the public Kilo GET entirely.
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/h" "$TMP/repo"
export MULTI_HOME="$TMP/h" MULTI_CONFIG="$TMP/h/config.toml"
export MULTI_PROVIDERS_ENV="$TMP/h/providers.env" MULTI_RUNS_DIR="$TMP/runs"
export MULTI_KILO_TRAINING_FIXTURE="$TMP/models.json" NT_DIR="$TMP"
export PATH="$TMP/bin:$PATH" TEST_KEY=fixture-key GEMINI_API_KEY=fixture-key
fail=0
say() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
contains() { say "$1" "$(grep -cF -- "$3" "$2" 2>/dev/null)" "1"; }
cat > "$TMP/models.json" <<'JSON'
{"data":[
  {"id":"train:free","mayTrainOnYourPrompts":true},
  {"id":"safe:free","mayTrainOnYourPrompts":false},
  {"id":"safe-two:free","mayTrainOnYourPrompts":false},
  {"id":"safe/silent","mayTrainOnYourPrompts":false},
  {"id":"paid-train","mayTrainOnYourPrompts":true},
  {"id":"paid-safe","mayTrainOnYourPrompts":false},
  {"id":"missing:free"}, {"id":"missing-paid"}
]}
JSON

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in --version) echo codex-fixture; exit 0 ;; login) echo 'Logged in'; exit 0 ;; esac
model='<default>'; out=''
while [ $# -gt 0 ]; do
  case "$1" in -m) model="$2"; shift 2 ;; -o) out="$2"; shift 2 ;; *) shift ;; esac
done
echo "codex $model" >> "$NT_DIR/sent"
printf '%s\n' 'codex: NO OUTPUT — this is model text, not a marker' > "$out"
STUB
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
bin="${0##*/}"
if [ "${2:-}" = models ]; then
  if [ "$bin" = kilo ]; then
    printf '%s\n' kilo/train:free kilo/safe:free kilo/safe-two:free
  else
    printf '%s\n' opencode/train opencode/other opencode-go/safe
  fi
  exit 0
fi
model=''
while [ $# -gt 0 ]; do
  case "$1" in -m) model="$2"; shift 2 ;; *) shift ;; esac
done
echo "$bin $model" >> "$NT_DIR/sent"
echo '{"type":"step_start","timestamp":1000,"part":{}}'
case "$model" in
  */silent) ;;
  *) echo '{"type":"text","timestamp":1600,"part":{"text":"fixture answer"}}' ;;
esac
STUB
cp "$TMP/bin/opencode" "$TMP/bin/kilo"
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "headless ${ANTHROPIC_MODEL:-<default>}" >> "$NT_DIR/sent"
echo 'fixture answer'
STUB
cat > "$TMP/bin/gemini" <<'STUB'
#!/usr/bin/env bash
model='<default>'
while [ $# -gt 0 ]; do
  case "$1" in -m) model="$2"; shift 2 ;; *) shift ;; esac
done
echo "gemini $model" >> "$NT_DIR/sent"
echo 'fixture answer'
STUB
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *https://api.kilo.ai/api/gateway/models*)
    echo "get $*" >> "$NT_DIR/gets"
    cat "$NT_DIR/models.json"
    exit "${NT_CURL_RC:-0}" ;;
  *) echo "probe $*" >> "$NT_DIR/probes"
     case "$*" in *busy*) printf 'HTTP/1.1 503 Busy\r\n\r\n{}\n503' ;;
       *) printf 'HTTP/1.1 200 OK\r\n\r\n{}\n200' ;; esac ;;
esac
STUB
chmod +x "$TMP/bin/"*
. "$TREE/scripts/providers.sh"
cfg() { cat > "$MULTI_CONFIG"; }
run() {
  : > "$TMP/sent"; : > "$TMP/probes"
  bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/$1" --repo "$TMP/repo" "${@:2}" > "$TMP/ask.log" 2>&1
}

echo "== the one verdict table, including exact hosts and account overrides =="
multi_kilo_training_catalogue > "$TMP/rows"; MULTI_KILO_TRAINING_FILE="$TMP/rows"
check() { say "$1 $2 $3" "$(multi_training_verdict "$1" "$2" "$3")" "$4"; }
check codex gpt '' unknown
check claude-headless claude https://api.anthropic.com/v1 no
check claude-headless claude https://API.ANTHROPIC.COM:443/v1 no
check claude-headless x:free https://openrouter.ai/api yes
check claude-headless paid https://openrouter.ai/api unknown
check claude-headless x https://api.deepseek.com/anthropic yes
check claude-headless x https://api.z.ai/api/anthropic yes
check claude-headless x https://open.bigmodel.cn/api yes
check claude-headless x https://other.example unknown
check claude-headless x https://api.anthropic.com.evil.example unknown
check claude-headless x https://api.anthropic.com@evil.example unknown
check opencode opencode/free '' yes
check opencode opencode-go/paid '' unknown
check opencode other/model '' unknown
check kilo kilo/train:free '' yes
check kilo kilo/safe:free '' no
check kilo kilo/paid-train '' yes
check kilo kilo/paid-safe '' no
check kilo kilo/missing:free '' yes
check kilo kilo/missing-paid '' unknown
check gemini '<default>' '' yes
for kind in codex claude-headless opencode kilo gemini; do
  MULTI_TRAINING_OVERRIDE=false check "$kind" x:free https://api.deepseek.com no
  MULTI_TRAINING_OVERRIDE=true check "$kind" paid-safe https://api.anthropic.com yes
done
MULTI_KILO_TRAINING_FILE=''
check kilo kilo/x:free '' yes
check kilo kilo/x '' unknown

echo "== switch off: all backends run, answering model sidecars, status is runner-owned =="
cfg <<'TOML'
default_profile = "p"
[backends.codex]
type = "codex"
[backends.opencode]
type = "opencode"
models = ["opencode/silent", "opencode-go/answer"]
[backends.kilo]
type = "kilo"
models = ["kilo/safe:free"]
[backends.anthropic]
type = "claude-headless"
base_url = "https://api.anthropic.com"
api_key_env = "TEST_KEY"
models = ["claude"]
stall = 20
timeout = 20
[backends.gemini]
type = "gemini"
[profiles]
p = ["codex", "opencode", "kilo", "anthropic", "gemini"]
TOML
run off; say "default run succeeds" "$?" 0
say "all five CLI backends plus one opencode fallback were called" "$(wc -l < "$TMP/sent" | tr -d ' ')" 6
say "codex default verdict" "$(cat "$TMP/off-codex.txt.trains")" 'unknown <default>'
say "opencode: every model sent the prompt leaves a line (stalled yes, then answering)" "$(cat "$TMP/off-opencode.txt.trains")" 'yes opencode/silent
unknown opencode-go/answer'
say "kilo catalogue verdict overrides free suffix" "$(cat "$TMP/off-kilo.txt.trains")" 'no kilo/safe:free'
say "anthropic verdict" "$(cat "$TMP/off-anthropic.txt.trains")" 'no claude'
say "gemini default verdict" "$(cat "$TMP/off-gemini.txt.trains")" 'yes <default>'
say "model text cannot forge status" "$([ -e "$TMP/off-codex.txt.dead" ] && echo dead || echo alive)" alive
contains "fallback is announced" "$TMP/off-opencode.txt" 'fell back to opencode-go/answer'
{ echo 'no_train = false'; cat "$MULTI_CONFIG"; } > "$TMP/explicit-off.toml"
MULTI_CONFIG="$TMP/explicit-off.toml" run explicit-off
say "explicit false preserves all backends and fallback" "$?:$(wc -l < "$TMP/sent" | tr -d ' ')" '0:6'

echo "== switch on: filter chains and pins, keep denied participants in the roster =="
cfg <<'TOML'
default_profile = "p"
[backends.kilo]
type = "kilo"
models = ["kilo/train:free", "kilo/safe:free", "kilo/safe-two:free"]
[backends.codex]
type = "codex"
[backends.opencode]
type = "opencode"
models = ["opencode/train", "opencode-go/unknown"]
[backends.router]
type = "claude-headless"
base_url = "https://openrouter.ai/api"
api_key_env = "TEST_KEY"
models = ["train:free", "paid"]
[backends.gemini]
type = "gemini"
[profiles]
p = ["kilo", "codex", "opencode", "router", "gemini"]
TOML
cp "$MULTI_CONFIG" "$TMP/base.toml"
run on --no-train; say "one safe Kilo answers" "$?" 0
say "only the safe model received the prompt" "$(cat "$TMP/sent")" 'kilo kilo/safe:free'
say "only no sidecar" "$(cat "$TMP/on-kilo.txt.trains")" 'no kilo/safe:free'
for backend in codex opencode router gemini; do
  contains "$backend sat out" "$TMP/on-$backend.txt.dead" 'SAT OUT — may train on prompts'
  contains "$backend has the account hint" "$TMP/on-$backend.txt.dead" "set trains = false under [backends.$backend]"
  say "$backend stays in roster" "$(grep -c "^$backend$" "$TMP/on.run")" 1
  say "$backend has no training sidecar because nothing was sent" "$([ -e "$TMP/on-$backend.txt.trains" ] && echo sent || echo none)" none
done
contains "unknown is explained" "$TMP/on-codex.txt.dead" '<default>: unknown'
contains "every denied chain member is explained" "$TMP/on-opencode.txt.dead" 'opencode/train: yes, opencode-go/unknown: unknown'
say "no headless probe before denial" "$(cat "$TMP/probes")" ''

run pin --no-train --backend kilo:kilo/train:free; say "a blocked pin does not borrow safe fallbacks" "$?" 1
say "blocked pin never launches" "$(cat "$TMP/sent")" ''
contains "blocked pin is named" "$TMP/pin-kilo.txt.dead" 'kilo/train:free: yes'
run safe-pin --no-train --backend kilo:kilo/safe-two:free
say "safe pin stays exact, no fallback added" "$(cat "$TMP/sent")" 'kilo kilo/safe-two:free'
run auto --no-train --backend kilo --model ignored
# Kilo --model is opencode-only, so the configured Kilo chain still wins.
say "Kilo ignores opencode --model during filtering" "$(cat "$TMP/sent")" 'kilo kilo/safe:free'
run override-model --no-train --backend opencode --model opencode/train --fallback opencode-go/unknown
say "--model and --fallback are both checked" "$?:$(cat "$TMP/sent")" '1:'

echo "== config switch matches the flag and probe announces it =="
{ echo 'no_train = true'; cat "$TMP/base.toml"; } > "$MULTI_CONFIG"
run config-on; say "config no_train works without flag" "$?" 0
say "same selected model" "$(cat "$TMP/sent")" 'kilo kilo/safe:free'
say "probe prints one no-train line" "$(bash "$TREE/scripts/probe.sh" 2>/dev/null | grep -c '^no-train: on')" 1
say "bool accessor" "$(multi_config no-train)" true

echo "== autodetected Kilo lists and permitted fallback order =="
cfg <<'TOML'
default_profile = "p"
[backends.kilo]
type = "kilo"
models = []
[profiles]
p = ["kilo"]
TOML
MULTI_KILO_CANDIDATES='kilo/train:free' run autodetect --no-train
say "auto primary yes is removed, first no retained" "$(cat "$TMP/sent")" 'kilo kilo/safe:free'
cfg <<'TOML'
default_profile = "p"
[backends.kilo]
type = "kilo"
models = ["kilo/train:free", "kilo/safe/silent", "kilo/safe-two:free"]
[profiles]
p = ["kilo"]
TOML
run kilo-fallback --no-train
say "filtered Kilo fallback order" "$(cat "$TMP/sent")" "kilo kilo/safe/silent
kilo kilo/safe-two:free"
say "sidecar lists every Kilo model that was sent the prompt" "$(cat "$TMP/kilo-fallback-kilo.txt.trains")" 'no kilo/safe/silent
no kilo/safe-two:free'
# Headless pool selection has its own fallback path, also runner-owned.
cfg <<'TOML'
default_profile = "p"
[backends.api]
type = "claude-headless"
base_url = "https://api.anthropic.com"
api_key_env = "TEST_KEY"
models = ["busy", "answer"]
stall = 20
timeout = 20
[profiles]
p = ["api"]
TOML
run pools --no-train
say "headless answers using first available permitted pool" "$(cat "$TMP/sent")" 'headless answer'
say "headless sidecar follows pool selection" "$(cat "$TMP/pools-api.txt.trains")" 'no answer'
# Add safe OpenCode via an account override: both its fallback models are no.
cfg <<'TOML'
default_profile = "p"
[backends.opencode]
type = "opencode"
trains = false
models = ["opencode/silent", "opencode/answer"]
[profiles]
p = ["opencode"]
TOML
run permitted --no-train
say "allowed fallback order preserved" "$(cat "$TMP/sent")" "opencode opencode/silent
opencode opencode/answer"
say "account override covers every attempted model" "$(cat "$TMP/permitted-opencode.txt.trains")" 'no opencode/silent
no opencode/answer'
run denied-default --no-train --model opencode/train --backend opencode
say "run flags still honour the account override" "$(cat "$TMP/denied-default-opencode.txt.trains")" 'no opencode/train'
# A false override allows CLI defaults; true can block the normally safe API.
cfg <<'TOML'
default_profile = "p"
[backends.codex]
type = "codex"
trains = false
[backends.api]
type = "claude-headless"
trains = true
base_url = "https://api.anthropic.com"
api_key_env = "TEST_KEY"
models = ["claude"]
[profiles]
p = ["codex", "api"]
TOML
run accounts --no-train
say "false override permits a CLI default" "$(cat "$TMP/accounts-codex.txt.trains")" 'no <default>'
contains "true override blocks Anthropic API" "$TMP/accounts-api.txt.dead" 'claude: yes'
# Reuse the prefix to prove stale training sidecars do not survive a SAT OUT.
cfg <<'TOML'
default_profile = "p"
[backends.codex]
type = "codex"
[profiles]
p = ["codex"]
TOML
run accounts --no-train
say "reused prefix clears old .trains" "$([ -e "$TMP/accounts-codex.txt.trains" ] && echo stale || echo cleared)" cleared

echo "== bad boolean types stop config and the runner before calls =="
cp "$MULTI_CONFIG" "$TMP/valid.toml"
for key in no_train trains; do
  for value in '"false"' 0 1 1.0 '[false]' '{}'; do
    if [ "$key" = no_train ]; then
      { echo "no_train = $value"; cat "$TMP/valid.toml"; } > "$MULTI_CONFIG"
    else
      { cat "$TMP/valid.toml"; printf '\n[backends.extra]\ntype = "codex"\ntrains = %s\n' "$value"; } > "$MULTI_CONFIG"
    fi
    multi_config check > /dev/null 2> "$TMP/err"
    say "$key = $value rejected" "$?" 2
    contains "type error names $key" "$TMP/err" "$key must be a boolean"
    run invalid --no-train
    say "bad type launches nothing" "$?:$(cat "$TMP/sent")" '2:'
  done
done

echo "== Kilo cache: only clean complete results, no authentication, fixture offline =="
cp "$TMP/models.json" "$TMP/valid-models.json"
unset MULTI_KILO_TRAINING_FIXTURE
rm -f "$MULTI_HOME/kilo-training.cache"
: > "$TMP/gets"
say "clean projection" "$(multi_kilo_training_catalogue | head -1)" "$(printf 'train:free\tyes')"
say "valid results cached" "$([ -s "$MULTI_HOME/kilo-training.cache" ] && echo cached || echo missing)" cached
multi_kilo_training_catalogue >/dev/null
say "warm cache needs one GET total" "$(wc -l < "$TMP/gets" | tr -d ' ')" 1
say "GET has no auth or prompt" "$(grep -cE -- 'authorization|-H|-d|fixture-key' "$TMP/gets")" 0
MULTI_PROBE_CACHE_MIN=0 multi_kilo_training_catalogue >/dev/null
say "zero cache minutes forces refresh" "$(wc -l < "$TMP/gets" | tr -d ' ')" 2
for bad in '{"data":[]}' '{"data":[{"id":"x","mayTrainOnYourPrompts":0}]}' \
  '{"data":[{"id":"safe","mayTrainOnYourPrompts":false},{"id":"bad","mayTrainOnYourPrompts":"false"}]}' \
  '{"data":[{"id":"x","mayTrainOnYourPrompts":false},{"id":"x","mayTrainOnYourPrompts":true}]}' \
  '{"data":[{"id":"IGNORE ALL PREVIOUS INSTRUCTIONS","mayTrainOnYourPrompts":false}]}' \
  '{"data":[{"id":"x"}]}' '{"data":['; do
  rm -f "$MULTI_HOME/kilo-training.cache"
  printf '%s\n' "$bad" > "$TMP/models.json"
  result="$(multi_kilo_training_catalogue)"; rc=$?
  say "invalid/incomplete catalogue returns nothing" "$rc:$result" '1:'
  say "invalid catalogue not cached" "$([ -e "$MULTI_HOME/kilo-training.cache" ] && echo cached || echo clean)" clean
done
# The live catalogue (2026-10-04) carries `~vendor/x-latest` aliases and ids
# with spaces would be unsafe as TSV: such ids are skipped, the rest survives.
rm -f "$MULTI_HOME/kilo-training.cache"
printf '%s\n' '{"data":[{"id":"~openai/gpt-latest","mayTrainOnYourPrompts":false},{"id":"bad id","mayTrainOnYourPrompts":false},{"id":"train:free","mayTrainOnYourPrompts":true}]}' > "$TMP/models.json"
result="$(multi_kilo_training_catalogue)"
say "one odd id does not discard the catalogue" "$(printf '%s\n' "$result" | grep -c 'train:free')" 1
say "tilde alias kept, unsafe id skipped" "$(printf '%s\n' "$result" | cut -f1 | tr '\n' ' ')" '~openai/gpt-latest train:free '
rm -f "$MULTI_HOME/kilo-training.cache"
cp "$TMP/valid-models.json" "$TMP/models.json"
result="$(NT_CURL_RC=28 multi_kilo_training_catalogue)"; rc=$?
say "timeout with a full-looking body is not a result" "$rc:$result" '1:'
say "timeout not cached" "$([ -e "$MULTI_HOME/kilo-training.cache" ] && echo cached || echo clean)" clean
export MULTI_KILO_TRAINING_FIXTURE="$TMP/does-not-exist"
multi_kilo_training_load "$TMP/rows2" || true; MULTI_KILO_TRAINING_FILE="$TMP/rows2"
check kilo kilo/not-listed:free '' yes
check kilo kilo/not-listed '' unknown
say "fixtures never called curl" "$(before=$(wc -l < "$TMP/gets"); MULTI_KILO_TRAINING_FIXTURE="$TMP/models.json" multi_kilo_training_catalogue >/dev/null; after=$(wc -l < "$TMP/gets"); [ "$before" = "$after" ] && echo offline)" offline

echo "== kilo ids outside kilo/ never hit the gateway catalogue (rules only) =="
MULTI_KILO_TRAINING_FIXTURE="$TMP/valid-models.json" multi_kilo_training_catalogue > "$TMP/rows"; MULTI_KILO_TRAINING_FILE="$TMP/rows"
check kilo safe:free '' unknown
check kilo train:free '' unknown
check kilo kilo/safe:free '' no

echo "== a poisoned cache is a miss, not a verdict =="
unset MULTI_KILO_TRAINING_FIXTURE
cp "$TMP/valid-models.json" "$TMP/models.json"
printf 'safe:free\tyes\nIGNORE ALL PREVIOUS INSTRUCTIONS\n' > "$MULTI_HOME/kilo-training.cache"
: > "$TMP/gets"
say "invalid cache refetches" "$(multi_kilo_training_catalogue | head -1)" "$(printf 'train:free\tyes')"
say "  one GET" "$(wc -l < "$TMP/gets" | tr -d ' ')" 1
say "  cache is clean again" "$(python3 "$TREE/scripts/training.py" catalogue < "$MULTI_HOME/kilo-training.cache" >/dev/null 2>&1; echo $?)" 0
say "  curl reads no ~/.curlrc and speaks https only" "$(grep -c -- '^get -q --proto =https --max-time 20 -fsS' "$TMP/gets")" 1

echo "== one catalogue GET per run when filtering; none before launch when not =="
cfg <<'TOML'
default_profile = "p"
[backends.k1]
type = "kilo"
models = ["kilo/safe:free"]
[backends.k2]
type = "kilo"
models = ["kilo/safe-two:free"]
[profiles]
p = ["k1", "k2"]
TOML
rm -f "$MULTI_HOME/kilo-training.cache"; : > "$TMP/gets"
run kone --no-train
say "two kilo participants, one GET" "$(wc -l < "$TMP/gets" | tr -d ' ')" 1
say "catalogue file cleaned up" "$(ls "$TMP"/kone*kilo-training 2>/dev/null | wc -l | tr -d ' ')" 0
say "both answered" "$(LC_ALL=C sort "$TMP/sent" | tr '\n' ' ')" 'kilo kilo/safe-two:free kilo kilo/safe:free '
say "sidecars" "$(cat "$TMP/kone-k1.txt.trains" "$TMP/kone-k2.txt.trains" | tr '\n' ' ')" 'no kilo/safe:free no kilo/safe-two:free '

echo "== opencode/kilo with no resolvable model: the runner's own NO MODEL, not SAT OUT =="
cfg <<'TOML'
default_profile = "p"
[backends.kilo]
type = "kilo"
models = []
[profiles]
p = ["kilo"]
TOML
mkdir -p "$TMP/empty"; printf '#!/usr/bin/env bash\n[ "${2:-}" = models ] && exit 0\nexit 0\n' > "$TMP/empty/kilo"; chmod +x "$TMP/empty/kilo"
rm -f "$MULTI_HOME"/*.cache
PATH="$TMP/empty:$PATH" run nomodel --no-train
say "NO MODEL reported" "$(head -1 "$TMP/nomodel-kilo.txt" | cut -c1-14)" "kilo: NO MODEL"
say "not a SAT OUT" "$(grep -c 'SAT OUT' "$TMP/nomodel-kilo.txt")" 0

echo "== every backend type has an arm in every per-type switch of ask.sh =="
blocks="$(grep -c 'case "\$type" in' "$TREE/scripts/ask.sh")"
for t in $(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import config; print(*config.TYPES)' "$TREE/scripts"); do
  arms="$(awk -v t="$t" '/case "\$type" in/{b=1} b && $0 ~ ("^[ \t]+([a-z-]+\\|)*" t "(\\|[a-z-]+)*\\)"){c++} /^[ \t]*esac/{b=0} END{print c+0}' "$TREE/scripts/ask.sh")"
  say "$t has an arm in all $blocks switches" "$arms" "$blocks"
done

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
