#!/usr/bin/env bash
# Checks ask.sh --read-dir: one extra directory every participant may read (the
# prepared skill copy of /multi:skill). Each harness gets it its own way, and a
# run without the flag launches exactly as before. Stub CLIs on PATH record the
# argv and env they were really started with -- no network, no keys, no models.
#
#   bash scripts/test-read-dir.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/h" "$TMP/rec" "$TMP/skill dir/references"
REC="$TMP/rec"

# Every stub writes one arg per line, so a path with a space stays one arg.
cat > "$TMP/bin/codex" <<STUB
#!/usr/bin/env bash
out=""; : > "$REC/codex.argv"
for a in "\$@"; do printf '%s\n' "\$a" >> "$REC/codex.argv"; done
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && echo "CODEX ANSWER" > "\$out"
STUB
cat > "$TMP/bin/opencode" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = models ] && { echo m; exit 0; }
printf '%s' "\${OPENCODE_CONFIG_CONTENT:-}" > "$REC/opencode.config"
echo "OPENCODE ANSWER"
STUB
cat > "$TMP/bin/claude" <<STUB
#!/usr/bin/env bash
: > "$REC/claude.argv"
for a in "\$@"; do printf '%s\n' "\$a" >> "$REC/claude.argv"; done
echo "CLAUDE ANSWER"
STUB
cat > "$TMP/bin/gemini" <<STUB
#!/usr/bin/env bash
: > "$REC/gemini.argv"
for a in "\$@"; do printf '%s\n' "\$a" >> "$REC/gemini.argv"; done
echo "GEMINI ANSWER"
STUB
chmod +x "$TMP/bin/"*
cat > "$TMP/h/config.toml" <<'EOF'
default_profile = "p"
[backends.codex]
type = "codex"
[backends.opencode]
type = "opencode"
models = ["m"]
[backends.openrouter]
type = "claude-headless"
base_url = "https://example.test/api"
models = ["free/one"]
[backends.gemini]
type = "gemini"
[profiles]
p = ["codex"]
EOF
export PATH="$TMP/bin:$PATH" MULTI_HOME="$TMP/h" OPENROUTER_API_KEY=test-key GEMINI_API_KEY=test-key
ALL="codex,opencode:m,openrouter:pinned/model,gemini"
DIR="$TMP/skill dir"
DIR_PHYS="$(cd "$DIR" && pwd -P)"

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
# has_pair <argv file> <flag> <value>: the flag is followed by exactly that value.
has_pair() { awk -v f="$2" -v v="$3" 'p && $0==v {found=1} {p=($0==f)} END {exit !found}' "$1"; }
oc_external() { # the external_directory rule opencode was started with, as JSON
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["agent"]["multi-readonly"]["permission"]; print(json.dumps(p.get("external_directory")))' "$REC/opencode.config"
}

# --- without --read-dir: nothing new reaches any harness -------------------
rm -f "$REC"/*
"$HERE/ask.sh" --question q --out-prefix "$TMP/plain" --backend "$ALL" >/dev/null 2>&1
# A stub that never ran would make every "has no X" check below pass vacuously.
for f in codex.argv claude.argv gemini.argv opencode.config; do
  [ -s "$REC/$f" ] || bad "no --read-dir: $f not recorded -- that harness never launched"
done
grep -qx -- '--add-dir' "$REC/claude.argv" && bad "claude got --add-dir without --read-dir" || ok "no --read-dir: claude argv has no --add-dir"
grep -qx -- '--include-directories' "$REC/gemini.argv" && bad "gemini got --include-directories without --read-dir" || ok "no --read-dir: gemini argv has no --include-directories"
[ "$(oc_external)" = "null" ] && ok "no --read-dir: opencode has no external_directory rule" || bad "opencode got an external_directory rule without --read-dir: $(oc_external)"
cp "$REC/codex.argv" "$TMP/codex.plain"

# --- with --read-dir: each harness gets the directory its own way ----------
rm -f "$REC"/*
"$HERE/ask.sh" --question q --out-prefix "$TMP/rd" --backend "$ALL" --read-dir "$DIR" >/dev/null 2>&1
has_pair "$REC/claude.argv" --add-dir "$DIR_PHYS" && ok "claude: --add-dir <dir>" || bad "claude argv lacks --add-dir $DIR_PHYS: $(tr '\n' ' ' < "$REC/claude.argv")"
has_pair "$REC/gemini.argv" --include-directories "$DIR_PHYS" && ok "gemini: --include-directories <dir>" || bad "gemini argv lacks --include-directories $DIR_PHYS: $(tr '\n' ' ' < "$REC/gemini.argv")"
want="$(python3 -c 'import json,sys; print(json.dumps({sys.argv[1]+"/*": "allow"}))' "$DIR_PHYS")"
[ "$(oc_external)" = "$want" ] && ok "opencode: external_directory allows exactly <dir>/*" || bad "opencode external_directory: want $want, got $(oc_external)"
# codex reads outside its cwd under -s read-only already (live, 2026-10-04):
# the flag must not change how it is launched. The -o path differs per prefix.
sed 's#^/.*-codex\.txt$#OUT#' "$TMP/codex.plain" > "$TMP/a"; sed 's#^/.*-codex\.txt$#OUT#' "$REC/codex.argv" > "$TMP/b"
cmp -s "$TMP/a" "$TMP/b" && ok "codex: launch unchanged by --read-dir" || bad "codex argv changed by --read-dir"
# The read-only rest of the opencode agent must survive the added rule.
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["agent"]["multi-readonly"]["permission"]; sys.exit(not (p["*"]=="deny" and p["edit"]=="deny"))' "$REC/opencode.config" \
  && ok "opencode: deny-by-default kept" || bad "opencode lost its deny-by-default rules"

# --- a relative path is resolved; a missing one stops the run --------------
rm -f "$REC"/*
(cd "$TMP" && "$HERE/ask.sh" --question q --out-prefix "$TMP/rel" --backend "openrouter:pinned/model" --read-dir "skill dir" >/dev/null 2>&1)
has_pair "$REC/claude.argv" --add-dir "$DIR_PHYS" && ok "relative --read-dir made absolute" || bad "relative --read-dir not resolved: $(tr '\n' ' ' < "$REC/claude.argv" 2>/dev/null)"
"$HERE/ask.sh" --question q --out-prefix "$TMP/missing" --backend codex --read-dir "$TMP/nope" >/dev/null 2>"$TMP/missing.err"
rc=$?
# "unknown arg" also exits 2: the message must name the missing directory.
[ $rc -eq 2 ] && grep -qF "$TMP/nope" "$TMP/missing.err" && ok "missing --read-dir rejected (exit 2, names the dir)" \
  || bad "missing --read-dir not rejected properly: rc=$rc $(head -1 "$TMP/missing.err")"

# The path becomes an opencode permission glob: "/tmp/skill*/*" would also open
# /tmp/skill-private. A wildcard in the name is refused, not escaped.
mkdir -p "$TMP/sk*ll"
"$HERE/ask.sh" --question q --out-prefix "$TMP/glob" --backend codex --read-dir "$TMP/sk*ll" >/dev/null 2>"$TMP/glob.err"
rc=$?
[ $rc -eq 2 ] && grep -q 'wildcard' "$TMP/glob.err" && ok "wildcard in --read-dir refused" || bad "wildcard --read-dir: rc=$rc $(head -1 "$TMP/glob.err")"

# OpenCode's matcher also turns a backslash into a slash: /tmp/a\b would open
# /tmp/a/b. Only plain path characters pass.
mkdir -p "$TMP/a\\b"
"$HERE/ask.sh" --question q --out-prefix "$TMP/bs" --backend codex --read-dir "$TMP/a\\b" >/dev/null 2>"$TMP/bs.err"
rc=$?
[ $rc -eq 2 ] && ok "backslash in --read-dir refused" || bad "backslash --read-dir: rc=$rc"

# A folder named -P must be the folder, not a cd option (cd -P == cd $HOME).
mkdir -p "$TMP/cwd/-P"
rm -f "$REC"/*
(cd "$TMP/cwd" && "$HERE/ask.sh" --question q --out-prefix "$TMP/dashp" --backend "openrouter:pinned/model" --read-dir "-P" >/dev/null 2>&1)
has_pair "$REC/claude.argv" --add-dir "$(cd "$TMP/cwd/-P" && pwd -P)" && ok "--read-dir -P is the folder named -P" || bad "--read-dir -P: $(tr '\n' ' ' < "$REC/claude.argv" 2>/dev/null)"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
