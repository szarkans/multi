#!/usr/bin/env bash
# The run journal: ask.sh must write it, journal.py must collect every backend
# type's own token source, the archive must skip snapshots, and a second
# collect must replace the row instead of duplicating it. Stub CLIs on PATH —
# no network, no keys.
#
#   bash scripts/test-journal.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/h"

# codex stub: an answer in unified finding format + the real CLI's stderr tail.
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
[ -n "$out" ] && printf 'scripts/foo.sh:12 | HIGH | the counter is never reset\n' > "$out"
echo "tokens used" >&2
echo "1,234" >&2
STUB

# opencode stub: --format json events, incl. one step_finish with usage.
cat > "$TMP/bin/opencode" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"type":"step_start","timestamp":1,"part":{"id":"p1"}}'
printf '%s\n' '{"type":"tool_use","timestamp":2,"part":{"id":"p2","tool":"read","state":{"status":"completed","input":{"filePath":"a.sh"}}}}'
printf '%s\n' '{"type":"text","timestamp":3,"part":{"id":"p3","text":"lib/b.sh:34 | MEDIUM | unchecked return"}}'
printf '%s\n' '{"type":"step_finish","timestamp":4,"part":{"id":"p4","cost":0,"tokens":{"input":5000,"output":200,"reasoning":800,"cache":{"read":3000,"write":100}}}}'
STUB
chmod +x "$TMP/bin/codex" "$TMP/bin/opencode"

cat > "$TMP/h/config.toml" <<'CFG'
default_profile = "default"
[backends.codex]
type = "codex"
models = ["gpt-test"]
[backends.opencode]
type = "opencode"
models = ["oc/test-model"]
[profiles]
default = ["codex", "opencode"]
CFG

export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/h"
fail=0
say() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$3] got [$2]"; fail=1; fi; }

# --- e2e: ask.sh writes .prompt and the journal row ----------------------
"$HERE/ask.sh" --question "review this thing" --out-prefix "$TMP/sess42--test-run/review" >/dev/null 2>&1
[ -f "$TMP/sess42--test-run/review.prompt" ] && say "prompt copy written" yes yes || { echo "FAIL no .prompt"; fail=1; }
grep -q "review this thing" "$TMP/sess42--test-run/review.prompt" && echo "ok   prompt content" || { echo "FAIL prompt content"; fail=1; }

IDX="$TMP/h/journal/index.jsonl"
[ -f "$IDX" ] && say "index.jsonl exists" yes yes || { echo "FAIL no index"; fail=1; }
rows=$(grep -c . "$IDX" 2>/dev/null); say "one row collected" "$rows" 1
python3 - "$IDX" <<'PY'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip())
assert row["prompt"] == "review this thing", row.get("prompt")
assert row["session"] == {"id": "sess42", "slug": "test-run"}, row["session"]
b = {x["backend"]: x for x in row["backends"]}
cx = b["codex"]
assert cx["status"] == "ok", cx
assert cx["model"] == "gpt-test", cx["model"]
assert cx["tokens"]["total"] == 1234, cx["tokens"]
assert cx["findings_count"] == 1 and cx["findings"][0]["line"] == 12, cx["findings"]
assert cx["findings"][0]["file"] == "scripts/foo.sh", cx["findings"]
oc = b["opencode"]
assert oc["status"] == "ok", oc
t = oc["tokens"]
assert t["input"] == 5000 and t["output"] == 200 and t["reasoning"] == 800, t
assert t["cache_read"] == 3000 and t["cache_write"] == 100, t
assert oc["calls"] == 1, oc["calls"]
assert oc["findings_count"] == 1 and oc["findings"][0]["severity"] == "MEDIUM", oc["findings"]
print("ok   e2e index row fields")
PY
[ $? -eq 0 ] || fail=1
arc=$(python3 -c "import json;print(json.loads(open('$IDX').read().strip())['archive'])")
[ -f "$TMP/h/journal/$arc/review-codex.txt" ] && say "answer archived" yes yes || { echo "FAIL archive"; fail=1; }
[ -f "$TMP/h/journal/$arc/review.prompt" ] && say "prompt archived" yes yes || { echo "FAIL prompt arch"; fail=1; }

# --- unit: dead backend, headless usage, snapshot skip, upsert -----------
R="$TMP/run2"; mkdir -p "$R/snapshot.ABC"
echo "opencode" > "$R/rev.run"; echo "opencode 42" >> "$R/rev.run"
echo "gemini" >> "$R/rev.run"; echo "gemini 7" >> "$R/rev.run"
printf 'gemini: NO OUTPUT — exit=1' > "$R/rev-gemini.txt.dead"
printf 'gemini: NO OUTPUT — exit=1' > "$R/rev-gemini.txt"
printf '## oc/test-model — 2 tool calls, 10s\n\n## Answer\nx.sh:1 | LOW | nits\n' > "$R/rev-opencode.txt"
printf '[multi] opencode model oc/test-model effort=harness-default\n' > "$R/rev-opencode.txt.log"
printf 'yes oc/test-model\nno oc/fallback\n' > "$R/rev-opencode.txt.trains"
# a claude-headless entry whose usage lives in a fake child transcript
echo "my-router" >> "$R/rev.run"; echo "my-router 99" >> "$R/rev.run"
printf 'answer tail\n[multi] answered by my-router model vendor/m-1\n' > "$R/rev-my-router.txt"
printf 'abc-sid-123\n' > "$R/rev-my-router.txt.sid"
mkdir -p "$TMP/h/child-home/projects/-tmp-x"
cat > "$TMP/h/child-home/projects/-tmp-x/abc-sid-123.jsonl" <<'JSONL'
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":50,"output_tokens_details":{"thinking_tokens":5}}}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":50,"output_tokens_details":{"thinking_tokens":5}}}}
{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":200,"output_tokens":20}}}
JSONL
printf 'junk in a snapshot\n' > "$R/snapshot.ABC/file.txt"
printf 'Q?\n' > "$R/rev.prompt"
# the judge's machine verdict: author matched by model name and by suffix,
# an unknown author must be ignored
cat > "$R/verdict.json" <<'JSON'
{"findings":[
 {"n":1,"author":"oc/test-model","file":"x.sh","line":1,"severity":"LOW","bucket":"verified"},
 {"n":2,"author":"gemini","file":"a.sh","line":9,"severity":"HIGH","bucket":"dropped"},
 {"n":3,"author":"ghost-model","file":"x.sh","line":2,"severity":"LOW","bucket":"dropped"}
]}
JSON

python3 "$HERE/journal.py" "$R" >/dev/null
rows=$(grep -c . "$IDX" 2>/dev/null); say "second run adds a row" "$rows" 2
python3 - "$IDX" "$TMP/h/journal" <<'PY'
import json, os, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
row = [r for r in rows if r["prefix"] == "rev"][0]
b = {x["backend"]: x for x in row["backends"]}
g = b["gemini"]
assert g["status"] == "failed" and "NO OUTPUT" in g["reason"], g
assert g["seconds"] == 7 and g["tokens"] is None, g
o = b["opencode"]
assert o["seconds"] == 42 and o["model"] == "oc/test-model", o
assert o["attempted"] == ["oc/test-model", "oc/fallback"], o["attempted"]
assert o["trains"][1]["verdict"] == "no", o["trains"]
h = b["my-router"]
assert h["status"] == "ok" and h["model"] == "vendor/m-1", h
t = h["tokens"]
# duplicate message ids deduped: m1 counted once, m2 added
assert t["input"] == 300 and t["output"] == 30, t
assert t["cache_read"] == 900 and t["cache_write"] == 50 and t["reasoning"] == 5, t
arc = os.path.join(sys.argv[2], row["archive"])
names = os.listdir(arc)
assert "rev-my-router.txt.transcript.jsonl" in names, names
assert not any("snapshot" in n for n in names), names
assert "rev-gemini.txt.dead" in names, names
assert row["verdict"]["findings"][0]["bucket"] == "verified", row["verdict"]
assert o.get("buckets") == {"verified": 1}, o.get("buckets")
assert o["findings"][0].get("bucket") == "verified", o["findings"]
assert g.get("buckets") == {"dropped": 1}, g.get("buckets")
assert not h.get("buckets"), h.get("buckets")
print("ok   unit row fields, archive, transcript")
PY
[ $? -eq 0 ] || fail=1

# upsert: collecting again must keep exactly one row per (run_dir, prefix)
python3 "$HERE/journal.py" "$R" >/dev/null
rows=$(grep -c . "$IDX" 2>/dev/null); say "re-collect upserts" "$rows" 2

# --stats renders a scoreboard from the rows collected above
MULTI_JOURNAL_DIR="$TMP/h/journal" python3 "$HERE/journal.py" --stats > "$TMP/stats.out" 2>&1
[ $? -eq 0 ] && grep -q "gpt-test" "$TMP/stats.out" && say "--stats prints" yes yes || { echo "FAIL --stats"; cat "$TMP/stats.out"; fail=1; }
grep -q "1/0 100%" "$TMP/stats.out" && grep -q "0/1 0%" "$TMP/stats.out" \
  && say "--stats cfm/drp" yes yes || { echo "FAIL cfm/drp"; cat "$TMP/stats.out"; fail=1; }

# journal = false in config stops collection
cat >> "$TMP/h/config.toml" <<'CFG'
journal = false
CFG
rm -f "$IDX"
"$HERE/ask.sh" --question q --out-prefix "$TMP/run3/r" >/dev/null 2>&1
[ ! -f "$IDX" ] && say "journal = false honoured" yes yes || { echo "FAIL journal wrote despite journal=false"; fail=1; }
MULTI_JOURNAL=0 sh -c 'export MULTI_HOME="'$TMP/h2'"; mkdir -p "$MULTI_HOME"; cp "'$TMP/h/config.toml'" "$MULTI_HOME/"; sed -i "/^journal/d" "$MULTI_HOME/config.toml"; "'$HERE'/ask.sh" --question q --out-prefix "'$TMP'/run4/r" >/dev/null 2>&1'
[ ! -f "$TMP/h2/journal/index.jsonl" ] && say "MULTI_JOURNAL=0 honoured" yes yes || { echo "FAIL env off"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
