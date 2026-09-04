#!/usr/bin/env bash
# config.py is the one place backends and profiles live. This checks that it
# resolves what the user wrote, refuses what would run the wrong thing, and
# that a missing file means the built-in default, not a dead plugin.
#
#   bash scripts/test-config.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MULTI_HOME="$TMP/h"
CFG="$TREE/scripts/config.py"
py="$(command -v python3 || command -v python)"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
resolve(){ "$py" "$CFG" resolve "$@" 2>"$TMP/err"; }

echo "== no file: the built-in default runs the plugin as before =="
say "check names the default" "$("$py" "$CFG" check | head -1)" "config: built-in default"
say "default profile is codex, opencode, openrouter" "$(resolve | cut -f1 | tr '\n' ' ')" "codex opencode openrouter "
say "both = the two CLIs" "$(resolve --backend both | cut -f1 | tr '\n' ' ')" "codex opencode "
say "all = every backend" "$(resolve --backend all | cut -f1 | tr '\n' ' ')" "codex opencode openrouter gemini "
say "codex default timeout 600" "$(resolve --backend codex | cut -f8)" "600"
say "--timeout raises every backend to at least N" "$(resolve --backend codex,opencode --timeout 450 | cut -f8 | tr '\n' ' ')" "600 450 "
say "openrouter key variable defaults to NAME_API_KEY" "$(resolve --backend openrouter | cut -f7)" "OPENROUTER_API_KEY"

echo "== backend:model pins exactly that model, first colon only =="
line="$(resolve --backend 'openrouter:z-ai/glm-5.2:free')"
say "pinned model keeps its own colon" "$(printf '%s' "$line" | cut -f4)" "z-ai/glm-5.2:free"
say "pinned entry still carries the chain (the runner ignores it)" "$(printf '%s' "$line" | cut -f5 | cut -d' ' -f1)" "z-ai/glm-5.2:free"

echo "== repeats get -2, -3 suffixes, unique across the run =="
say "suffixes" "$(resolve --backend codex:a,codex:b,opencode,codex | cut -f1 | tr '\n' ' ')" "codex codex-2 opencode codex-3 "
say "an empty pin is refused" "$(resolve --backend 'codex:' >/dev/null; echo $?)" "2"

echo "== a typo stops the run =="
resolve --backend gpt >/dev/null; say "unknown backend exits 2" "$?" "2"
say "the error names what exists" "$(grep -c 'backends: codex' "$TMP/err")" "1"

echo "== init writes the default, twice is a no-op, relative MULTI_CONFIG works =="
( cd "$TMP" && MULTI_CONFIG=rel.toml "$py" "$CFG" init >/dev/null ); say "relative MULTI_CONFIG" "$([ -s "$TMP/rel.toml" ] && echo yes || echo no)" "yes"
say "init" "$("$py" "$CFG" init | head -1)" "wrote: $MULTI_HOME/config.toml"
say "init again" "$("$py" "$CFG" init)" "exists: $MULTI_HOME/config.toml"
say "written default validates" "$("$py" "$CFG" check | head -1)" "config: $MULTI_HOME/config.toml"

echo "== a user config: two headless endpoints, profiles, per-backend knobs =="
cat > "$MULTI_HOME/config.toml" <<'EOF'
default_profile = "normal"   # comments survive

[backends.openrouter]
type = "claude-headless"
base_url = "https://openrouter.ai/api//"
models = ["a/one:free", "b/two"]

[backends.zcode]
type = "claude-headless"
base_url = "https://example.test/anthropic"
api_key_env = "ZAI_KEY"
models = ["glm-5"]

[backends.codex]
type = "codex"
timeout = 17

[backends.opencode]
type = "opencode"
models = ["oc/one", "oc/two"]
stall = 2

[profiles]
normal = ["openrouter:b/two", "zcode", "codex"]
cheap  = ["opencode", "opencode"]
EOF
say "default profile" "$(resolve | cut -f1,4 | tr '\t\n' ': ')" "openrouter:b/two zcode:- codex:- "
say "named profile" "$(resolve --backend cheap | cut -f1 | tr '\n' ' ')" "opencode opencode-2 "
say "trailing slashes stripped from base_url" "$(resolve --backend openrouter | cut -f6)" "https://openrouter.ai/api"
say "custom api_key_env" "$(resolve --backend zcode | cut -f7)" "ZAI_KEY"
say "per-backend timeout" "$(resolve --backend codex | cut -f8)" "17"
say "opencode stall" "$(resolve --backend opencode | cut -f9)" "2"
say "chain is space-separated in order" "$(resolve --backend opencode | cut -f5)" "oc/one oc/two"
say "backends lists every entry" "$("$py" "$CFG" backends | cut -f1 | tr '\n' ' ')" "openrouter zcode codex opencode "
say "gemini not configured here is unknown" "$(resolve --backend gemini >/dev/null; echo $?)" "2"

echo "== a user profile named both beats the built-in alias =="
cat >> "$MULTI_HOME/config.toml" <<'EOF'
both = ["zcode"]
EOF
say "profile both wins" "$(resolve --backend both | cut -f1 | tr '\n' ' ')" "zcode "
# A backend literally named like a generated suffix must not collide with one.
cat >> "$MULTI_HOME/config.toml" <<'EOF'
[backends.opencode-2]
type = "opencode"
EOF
say "suffixes stay unique next to a backend named opencode-2" "$(resolve --backend opencode,opencode,opencode-2 | cut -f1 | tr '\n' ' ')" "opencode opencode-2 opencode-2-2 "

echo "== what must be refused, before anything launches =="
refuse(){ # name toml-body expected-substring
  printf '%s\n' "$2" > "$MULTI_HOME/config.toml"
  "$py" "$CFG" check >/dev/null 2>"$TMP/err"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q -- "$3" "$TMP/err"; then echo "  ok   refused: $1"
  else echo "  FAIL not refused or wrong reason: $1 (rc=$rc): $(cat "$TMP/err")"; fail=1; fi
}
refuse "unknown type" 'default_profile="p"
[backends.x]
type="ollama"
[profiles]
p=["x"]' "type must be one of"
refuse "unknown key" 'default_profile="p"
[backends.x]
type="codex"
modle=["a"]
[profiles]
p=["x"]' "unknown key(s): modle"
refuse "profile names a missing backend" 'default_profile="p"
[backends.x]
type="codex"
[profiles]
p=["x","y"]' "names a backend that does not exist"
refuse "default_profile missing" 'default_profile="q"
[backends.x]
type="codex"
[profiles]
p=["x"]' "default_profile = 'q' names a profile that does not exist"
refuse "headless without base_url" 'default_profile="p"
[backends.x]
type="claude-headless"
models=["m"]
[profiles]
p=["x"]' "needs base_url"
refuse "headless without models" 'default_profile="p"
[backends.x]
type="claude-headless"
base_url="https://h"
models=[]
[profiles]
p=["x"]' "needs at least one model"
refuse "plain http to a remote host" 'default_profile="p"
[backends.x]
type="claude-headless"
base_url="http://router.example/api"
models=["m"]
[profiles]
p=["x"]' "must be https"
refuse "http to a host that merely starts with localhost" 'default_profile="p"
[backends.x]
type="claude-headless"
base_url="http://localhost.evil.example/api"
models=["m"]
[profiles]
p=["x"]' "must be https"
refuse "http with loopback as userinfo" 'default_profile="p"
[backends.x]
type="claude-headless"
base_url="http://127.0.0.1@evil.example/api"
models=["m"]
[profiles]
p=["x"]' "must be https"
refuse "a backend name that walks out of the run directory" 'default_profile="p"
[backends."../../pwned"]
type="codex"
[profiles]
p=["../../pwned"]' "letters, digits"
refuse "a model name with a space (bash would split it)" 'default_profile="p"
[backends.x]
type="codex"
models=["gpt 4"]
[profiles]
p=["x"]' "without whitespace"
refuse "a profile named like a backend" 'default_profile="x"
[backends.x]
type="codex"
[profiles]
x=["x"]' "share the name"
refuse "bad timeout" 'default_profile="p"
[backends.x]
type="codex"
timeout=0
[profiles]
p=["x"]' "timeout must be a positive integer"
refuse "reserved profile name" 'default_profile="p"
[backends.x]
type="codex"
[profiles]
p=["x"]
all=["x"]' "reserved"
refuse "a chain on a type that only takes one model" 'default_profile="p"
[backends.x]
type="codex"
models=["a","b"]
[profiles]
p=["x"]' "at most one model"
refuse "api_key_env that is not a variable name (it is eval'd by name in bash)" 'default_profile="p"
[backends.x]
type="codex"
api_key_env="$(touch /tmp/pwned)"
[profiles]
p=["x"]' "must be a variable name"
refuse "broken TOML" 'default_profile = "p
[backends.x]' "not valid TOML"

# localhost over plain http is a normal self-hosted router; nothing leaves the machine.
printf '%s\n' 'default_profile="p"
[backends.x]
type="claude-headless"
base_url="http://localhost:8080/api"
models=["m"]
[profiles]
p=["x"]' > "$MULTI_HOME/config.toml"
"$py" "$CFG" check >/dev/null 2>&1; say "http://localhost is allowed" "$?" "0"
mkdir -p "$TMP/dir.toml"
MULTI_CONFIG="$TMP/dir.toml" "$py" "$CFG" check >/dev/null 2>"$TMP/err"; say "an unreadable path is a config error, not a traceback" "$?:$(grep -c 'cannot read' "$TMP/err")" "2:1"

echo "== the repo's example config is valid and exercises every type =="
MULTI_CONFIG="$TREE/config.example.toml" "$py" "$CFG" check >/dev/null 2>"$TMP/err"; say "config.example.toml validates" "$?:$(cat "$TMP/err")" "0:"
say "every type appears in it" "$(MULTI_CONFIG="$TREE/config.example.toml" "$py" "$CFG" backends | cut -f2 | sort -u | tr '\n' ' ')" "claude-headless codex gemini opencode "
say "every key name in providers.example.env is read by some backend" "$(comm -23 <(grep -o '^export [A-Z_]*' "$TREE/providers.example.env" | sed 's/export //' | sort) <(MULTI_CONFIG="$TREE/config.example.toml" "$py" "$CFG" backends | cut -f5 | sort -u) | tr '\n' ' ')" ""

echo "== the vendored parser is the same parser =="
# Hide the stdlib tomllib and compare: the fallback must read the same file the same way.
if "$py" -c 'import tomllib' 2>/dev/null; then
  a="$("$py" "$CFG" backends)"
  b="$(SCRIPTS="$TREE/scripts" "$py" - <<'PY'
import sys, os, builtins, runpy
real = builtins.__import__
def fake(name, *a, **k):
    if name == "tomllib": raise ModuleNotFoundError(name)
    return real(name, *a, **k)
builtins.__import__ = fake
sys.argv = ["config.py", "backends"]
try: runpy.run_path(os.environ["SCRIPTS"] + "/config.py", run_name="__main__")
except SystemExit: pass
PY
)"
  say "vendored tomli reads the same backends" "$b" "$a"
else
  echo "  ok   (no stdlib tomllib here — the vendored parser is what already ran above)"
fi

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
