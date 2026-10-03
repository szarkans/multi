#!/usr/bin/env bash
# Per-model effort through the only transport; every CLI and curl is a stub.
set -euo pipefail
TREE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/trace" "$TMP/system" "$TMP/repo/home"
export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/home" MULTI_CONFIG="$TMP/home/config.toml"
export EFFORT_TRACE="$TMP/trace" OPENROUTER_API_KEY=test-key GEMINI_API_KEY=test-key
export GEMINI_CLI_SYSTEM_SETTINGS_PATH="$TMP/system/settings.json"
export CLAUDE_CODE_EXTRA_BODY='{"provider":{"order":["stub"],"allow_fallbacks":false},"output_config":{"format":{"type":"json_schema"}}}'
unset GEMINI_CLI_SYSTEM_DEFAULTS_PATH
cat > "$TMP/system/settings.json" <<'JSON'
{"security":{"disableYoloMode":true},"modelConfigs":{"customOverrides":[{"match":{"model":"unrelated"},"modelConfig":{"generateContentConfig":{"temperature":0.25}}}]}}
JSON
printf '%s\n' '{"ui":{"theme":"synthetic"}}' > "$TMP/system/system-defaults.json"

cat > "$TMP/bin/cli-stub" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
cli = Path(sys.argv[0]).name
args = sys.argv[1:]
def arg(flag, default=""):
    return args[args.index(flag) + 1] if flag in args else default
if cli == "curl":
    model = json.loads(arg("-d", "{}" )).get("model", "")
    print("429" if model == "busy" else "200", end="")
    sys.exit(0)
if cli == "opencode" and args == ["models"]:
    print("opencode/free-stub")
    sys.exit(0)
model = os.environ.get("ANTHROPIC_MODEL", "") if cli == "claude" else arg("-m")
record = {"argv": args, "model": model}
if cli == "opencode":
    # OpenCode merges an absent variant as {} and continues with defaults.
    record["applied_variant"] = None if model == "oc/no-variants" else arg("--variant", None)
if cli == "claude":
    record["extra_body"] = os.environ.get("CLAUDE_CODE_EXTRA_BODY")
if cli == "gemini":
    settings_path = Path(os.environ["GEMINI_CLI_SYSTEM_SETTINGS_PATH"])
    record["settings_path"] = str(settings_path)
    record["settings"] = json.loads(settings_path.read_text())
    defaults = Path(os.environ.get("GEMINI_CLI_SYSTEM_DEFAULTS_PATH") or settings_path.with_name("system-defaults.json"))
    record["defaults"] = json.loads(defaults.read_text()) if defaults.exists() else None
name = "%s-%s-%s.json" % (os.environ["EFFORT_TAG"], cli, model.encode().hex())
(Path(os.environ["EFFORT_TRACE"]) / name).write_text(json.dumps(record))
if cli == "codex":
    Path(arg("-o")).write_text("stub answer\n")
elif cli == "opencode":
    if model != os.environ.get("SILENT_MODEL"):
        print(json.dumps({"type":"text","part":{"text":"stub answer"}}))
    else:
        print(json.dumps({"type":"step_start","part":{}}))
else:
    print("stub answer")
sys.exit(int(os.environ.get("STUB_EXIT", "0")))
PY
chmod +x "$TMP/bin/cli-stub"
for cli in codex opencode claude gemini curl; do ln -s cli-stub "$TMP/bin/$cli"; done

config() {
  cat > "$MULTI_CONFIG" <<'TOML'
default_profile = "p"
[backends.cx]
type = "codex"
models = ["cx-model"]
[backends.oc]
type = "opencode"
models = ["oc/model:free", "oc/fallback"]
[backends.openrouter]
type = "claude-headless"
base_url = "https://fake.invalid/api"
models = ["busy", "head/model"]
stall = 1800
[backends.gm]
type = "gemini"
api_key_env = "GEMINI_API_KEY"
models = ["gemini-3.5-flash"]
[profiles]
p = ["cx", "oc", "openrouter:head/model", "gm"]
TOML
}
run() {
  EFFORT_TAG="$1" bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/$1" "${@:2}" >/dev/null
}
config
run before
# Each effort table is independent of the configured model list: a one-off
# backend:model pin or --model override must also find its exact entry.
python3 - "$MULTI_CONFIG" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
for backend, entries in {
    "cx": '"cx-model"="high", "cx-other"="low", "future-model"="turbo-v2"',
    "oc": '"oc/model:free"="high", "oc/fallback"="low"',
    "openrouter": '"head/model"="max", "other/model"="low"',
}.items():
    s=s.replace('[backends.%s]\n' % backend, '[backends.%s]\neffort={%s}\n' % (backend,entries))
p.write_text(s)
PY
run configured
run overridden --effort xhigh
run no-entry --backend cx:no-entry,oc:no-entry,openrouter:no-entry,gm:no-entry
run explicit-no-entry --backend cx:no-entry,oc:no-entry,openrouter:no-entry,gm:no-entry --effort turbo-v2
run loose --backend cx:future-model
run unavailable-variant --backend oc:oc/no-variants --effort high
run fallback --backend oc
SILENT_MODEL='oc/model:free' run fallback-effort --backend oc
run pools --backend openrouter
SILENT_MODEL='oc/model:free' run override-fallback --backend oc --effort turbo-v2
run pins --backend cx:cx-other,openrouter:other/model,oc:oc/fallback
run override-model --backend cx --codex-model cx-other
cp "$MULTI_CONFIG" "$TMP/repo/home/config.toml"
python3 - "$TMP/repo/home/config.toml" <<'PYFIXTURE'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('"cx-model"="high"', '"cx-model"="wrong-repo"'))
PYFIXTURE
(cd "$TMP"; MULTI_CONFIG=home/config.toml run relative --repo "$TMP/repo")
(cd "$TMP"; unset MULTI_CONFIG; MULTI_HOME=home run relative-home --repo "$TMP/repo")
(cd "$TMP"; MULTI_CONFIG=home/config.toml run detached --detach --repo "$TMP/repo")
n=0
while [ ! -e "$TMP/detached.run" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n+1)); done
bash "$TREE/scripts/wait.sh" --prefix "$TMP/detached" >/dev/null

python3 - "$TMP" <<'PY'
import json, os, sys
from pathlib import Path
root=Path(sys.argv[1]); trace=root/'trace'
def get(tag, cli, model):
    return json.loads((trace/('%s-%s-%s.json' % (tag,cli,model.encode().hex()))).read_text())
def effort(r):
    return next(x.split('=',1)[1] for x in r['argv'] if x.startswith('model_reasoning_effort='))
def variant(r):
    a=r['argv']; return a[a.index('--variant')+1] if '--variant' in a else None
def normalized(r):
    a=list(r['argv'])
    for flag in ('-o','--session-id'):
        if flag in a: a[a.index(flag)+1]='<run-specific>'
    return a
assert effort(get('before','codex','cx-model'))=='medium'
assert effort(get('configured','codex','cx-model'))=='high'
assert effort(get('overridden','codex','cx-model'))=='xhigh'
assert effort(get('no-entry','codex','no-entry'))=='medium'
assert effort(get('explicit-no-entry','codex','no-entry'))=='turbo-v2'
assert effort(get('loose','codex','future-model'))=='turbo-v2'
for tag in ('relative','relative-home','detached'):
    assert effort(get(tag,'codex','cx-model'))=='high'
assert effort(get('pins','codex','cx-other'))=='low'
assert effort(get('override-model','codex','cx-other'))=='low'
print('ok   Codex explicit effort > exact entry > medium; loose tokens, pins and model overrides')
print('ok   relative MULTI_CONFIG/MULTI_HOME remain anchored across --repo and --detach')
assert variant(get('before','opencode','oc/model:free')) is None
assert variant(get('configured','opencode','oc/model:free'))=='high'
assert variant(get('fallback-effort','opencode','oc/fallback'))=='low'
assert variant(get('pins','opencode','oc/fallback'))=='low'
assert variant(get('overridden','opencode','oc/model:free'))=='xhigh'
assert variant(get('explicit-no-entry','opencode','no-entry'))=='turbo-v2'
assert variant(get('override-fallback','opencode','oc/fallback'))=='turbo-v2'
assert get('unavailable-variant','opencode','oc/no-variants')['applied_variant'] is None
assert not (root/'unavailable-variant-oc.txt.dead').exists()
assert 'unavailable variants use harness defaults' in (root/'unavailable-variant-oc.txt.log').read_text()
print('ok   OpenCode primary, colon-containing model and fallback each select their own variant')
before=json.loads(get('before','claude','head/model')['extra_body'])
for tag, model, level in [('configured','head/model','max'),('pools','head/model','max'),('pins','other/model','low'),('overridden','head/model','xhigh'),('explicit-no-entry','no-entry','turbo-v2')]:
    body=json.loads(get(tag,'claude',model)['extra_body'])
    assert body['output_config']['effort']==level
    assert body['provider']==before['provider']
    assert body['output_config']['format']==before['output_config']['format']
print('ok   headless exact model after pool selection; extra-body routing and format survive')
for tag, model in [('configured','gemini-3.5-flash'),('overridden','gemini-3.5-flash'),('detached','gemini-3.5-flash'),('explicit-no-entry','no-entry')]:
    gm=get(tag,'gemini',model)
    assert gm['settings']==get('before','gemini','gemini-3.5-flash')['settings']
    assert gm['settings_path']==str(root/'system/settings.json')
    assert gm['defaults']=={'ui':{'theme':'synthetic'}}
    assert gm['argv']==['-p','q','-m',model,'--approval-mode','plan']
print('ok   Gemini historical argv/settings/defaults unchanged, including explicit effort and detached run')
for cli in ('opencode','claude','gemini'):
    r=get('no-entry',cli,'no-entry')
    # Expected historical argv, not just absence of the new flag.
    if cli=='opencode':
        assert r['argv']==['run','--pure','--agent','multi-readonly','--format','json','-m','no-entry','--dir','.','q']
        assert variant(r) is None
    elif cli=='claude':
        expected=['-p','q','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','user']
        assert r['argv'][:len(expected)]==expected
        assert r['argv'][len(expected):len(expected)+1] in ([],['--session-id'])
        assert r['extra_body']==get('before','claude','head/model')['extra_body']
    else:
        assert r['argv']==['-p','q','-m','no-entry','--approval-mode','plan']
        assert r['settings_path']==str(root/'system/settings.json')
for cli, model in [('codex','cx-model'),('opencode','oc/model:free'),('claude','head/model'),('gemini','gemini-3.5-flash')]:
    a=get('before',cli,model); b=get('configured',cli,model)
    if cli=='codex': b['argv']=[x.replace('model_reasoning_effort=high','model_reasoning_effort=medium') for x in b['argv']]
    if cli=='opencode':
        i=b['argv'].index('--variant'); del b['argv'][i:i+2]
    assert normalized(a)==normalized(b)
print('ok   without an entry historical argv/env/settings stay unchanged')
for tag in ('before','configured','overridden','relative','relative-home','detached'):
    for backend, model, level in [('cx','cx-model','medium' if tag=='before' else 'xhigh' if tag=='overridden' else 'high'),('oc','oc/model:free','harness-default' if tag=='before' else 'xhigh' if tag=='overridden' else 'high'),('openrouter','head/model','harness-default' if tag=='before' else 'xhigh' if tag=='overridden' else 'max'),('gm','gemini-3.5-flash','unsupported')]:
        log=(root/('%s-%s.txt.log' % (tag,backend))).read_text()
        assert '%s model %s effort=%s' % (backend,model,level) in log, (tag,backend,log)
assert 'oc model oc/fallback effort=low' in (root/'fallback-effort-oc.txt.log').read_text()
print('ok   per-backend effort records include defaults, overrides, actual fallback and unsupported Gemini')
PY

# Validation is offline and fails before any harness is launched.
python3 - "$TREE" <<'PY'
import importlib.util, sys
s=importlib.util.spec_from_file_location('multi_config',sys.argv[1]+'/scripts/config.py')
c=importlib.util.module_from_spec(s); s.loader.exec_module(c)
for kind in c.TYPES:
    cfg={'default_profile':'p','profiles':{'p':['x']},'backends':{'x':{'type':kind,'models':['m']}}}
    if kind=='claude-headless': cfg['backends']['x']['base_url']='https://fake.invalid'
    if kind=='gemini':
        for value in [{}, {'m':'high'}, {'m':4096}]:
            cfg['backends']['x']['effort']=value
            try: c.validate(cfg,'fixture')
            except c.ConfigError as e: assert 'Gemini CLI has no effort control; not supported' in str(e)
            else: raise AssertionError((kind,value))
        continue
    for value in ['turbo-v2','ultrathink','model:level','HIGH','4096']:
        cfg['backends']['x']['effort']={'m':value}
        assert c.validate(cfg,'fixture')['backends']['x']['effort']['m']==value
    for value in [42,True,[],{},'', 'high low','high\t','high\n','high\u00a0']:
        cfg['backends']['x']['effort']={'m':value}
        try: c.validate(cfg,'fixture')
        except c.ConfigError as e: assert 'effort' in str(e) and 'm' in str(e)
        else: raise AssertionError((kind,value))
    for value in ['high',[],{'bad model':'high'},{'':'high'},{'m\n':'high'}]:
        cfg['backends']['x']['effort']=value
        try: c.validate(cfg,'fixture')
        except c.ConfigError as e: assert 'effort' in str(e)
        else: raise AssertionError((kind,value))
print('ok   effort accepts future/model-specific tokens; malformed shapes rejected; Gemini tables rejected')
PY
python3 - "$MULTI_CONFIG" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('"cx-model"="high"','"cx-model"="two words"'))
PY
if EFFORT_TAG=invalid bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/invalid" >/dev/null 2>"$TMP/invalid.err"; then
  echo 'FAIL invalid config started a run'; exit 1
fi
if ! grep -q 'effort' "$TMP/invalid.err" || [ -e "$TMP/invalid.run" ]; then
  echo 'FAIL invalid config was not stopped before launch'; exit 1
fi
echo 'ok   malformed config stops the transport before launch'
for value in '' 'high low' $'high\t' $'high\n'; do
  if EFFORT_TAG=invalid-flag bash "$TREE/scripts/ask.sh" --question q --out-prefix "$TMP/invalid-flag" --effort "$value" >/dev/null 2>"$TMP/invalid-flag.err"; then
    echo 'FAIL invalid effort flag started a run'; exit 1
  fi
  grep -q 'non-empty token without whitespace' "$TMP/invalid-flag.err" || { echo 'FAIL unclear effort flag error'; exit 1; }
  [ ! -e "$TMP/invalid-flag.run" ] || { echo 'FAIL invalid effort flag reached launch'; exit 1; }
done
echo 'ok   malformed explicit effort fails before launch'
echo 'ALL PASS'
