#!/usr/bin/env bash
# The skill bodies must work on any host that reads SKILL.md, not only Claude
# Code (#30). Two things keep that true: no Claude-only path in a body, and the
# Claude `!` header and the "run it yourself" first step for other hosts name
# the same command — one drifting from the other is a host silently probing a
# different script.
#
#   bash scripts/test-portable.sh
set -uo pipefail
TREE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Own MULTI_HOME: the machine's real config must not shape this test.
export MULTI_HOME="$TMP/h"
fail=0
say(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }

echo "== no Claude-only path in any skill body =="
for pat in '~/.claude' '$HOME/.claude' 'CLAUDE_PLUGIN_ROOT' '.claude/skills' '.claude/multi'; do
  hits="$(grep -rnF -- "$pat" "$TREE"/skills/*/SKILL.md "$TREE"/skills/*/references/ 2>/dev/null | grep -v '_vendor' || true)"
  say "no '$pat' in skill bodies" "${hits:+$hits}" ""
done
# The plugin's own agents/*.md are the reviewer roles on every host; they must
# not lean on Claude paths either.
hits="$(grep -rnF -e '~/.claude' -e 'CLAUDE_PLUGIN_ROOT' "$TREE"/agents/ || true)"
say "no Claude-only path in agents/" "${hits:+$hits}" ""

echo "== the Claude header and the other-host first step name one command =="
for f in "$TREE"/skills/*/SKILL.md; do
  name="$(basename "$(dirname "$f")")"
  grep -q '^!`' "$f" || { echo "  skip $name (no probe header)"; continue; }
  header="$(grep -o '^!`[^`]*`' "$f")"
  # The relative command the header runs, e.g. ../../scripts/probe.sh
  hcmd="$(printf '%s' "$header" | grep -o '\.\./\.\./scripts/[a-z-]*\.sh' || true)"
  say "$name: header runs the probe via \${CLAUDE_SKILL_DIR}" "$(printf '%s' "$header" | grep -c 'CLAUDE_SKILL_DIR}/../../scripts/probe.sh')" "1"
  say "$name: exactly one probe header" "$(grep -c '^!`' "$f")" "1"
  step="$(grep -o '<dir of this SKILL.md>/[^`]*' "$f" || true)"
  scmd="$(printf '%s' "$step" | grep -o '\.\./\.\./scripts/[a-z-]*\.sh' || true)"
  say "$name: other-host first step exists" "$([ -n "$step" ] && echo yes || echo no)" "yes"
  say "$name: both name the same command" "$scmd" "$hcmd"
  # The header must be ONE plain path: the worktree shell gate (#26) refuses
  # sh -c, ||-chains, loops and ${VAR:-default}.
  say "$name: header is one plain path" "$(printf '%s' "$header" | grep -c '||\|sh -c\|:-')" "0"
done

echo "== the scripts a skill relies on exist where the header points =="
for s in probe run-dir snapshot collect-context review-prompt ask wait setup; do
  say "scripts/$s.sh present" "$([ -x "$TREE/scripts/$s.sh" ] && echo yes || echo no)" "yes"
done
for r in correctness security design execution verify; do
  say "agents/$r.md present" "$([ -f "$TREE/agents/$r.md" ] && echo yes || echo no)" "yes"
done

echo "== one version in every manifest =="
ver(){ sed -n '/"version"/{s/.*"version": *"\([^"]*\)".*/\1/p;q;}' "$1"; }
v="$(ver "$TREE/.claude-plugin/plugin.json")"
for m in .claude-plugin/marketplace.json .codex-plugin/plugin.json gemini-extension.json package.json; do
  say "$m says $v" "$(ver "$TREE/$m")" "$v"
done
say "CHANGELOG has a $v section" "$(grep -c "^## $v " "$TREE/CHANGELOG.md")" "1"

echo "== the SKILL.md frontmatter stays inside what every host reads =="
for f in "$TREE"/skills/*/SKILL.md; do
  name="$(basename "$(dirname "$f")")"
  fm="$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$f")"
  say "$name: frontmatter has name" "$(printf '%s\n' "$fm" | grep -c '^name: ')" "1"
  say "$name: frontmatter name matches directory" "$(printf '%s\n' "$fm" | sed -n 's/^name: *//p')" "$name"
  say "$name: frontmatter has description" "$(printf '%s\n' "$fm" | grep -c '^description:')" "1"
done

echo "== harnesses/skills.json is the one command list every adapter reads =="
catalog_out="$(python3 - "$TREE" <<'PY'
import json, os, re, sys

tree = sys.argv[1]
def rel(*p): return os.path.join(tree, *p)
problems = []

try:
    catalog = json.load(open(rel("harnesses", "skills.json")))
except Exception as error:
    print("FAIL\tskills.json parses\t%s" % error)
    raise SystemExit(0)

# 1. exactly the six user-facing commands, all named for the host's sigil.
if len(catalog) != 6:
    problems.append(("six entries", "found %d" % len(catalog)))
commands = [entry.get("command") for entry in catalog]
if len(set(commands)) != len(commands):
    problems.append(("commands are unique", str(commands)))
bad = [c for c in commands if not re.fullmatch(r"multi-[a-z-]+", c or "")]
if bad:
    problems.append(("every command starts with multi-", str(bad)))

# 2. every entry points at a real skill whose frontmatter agrees.
for entry in catalog:
    skill, command = entry.get("skill"), entry.get("command")
    path = rel("skills", skill, "SKILL.md")
    if not os.path.isfile(path):
        problems.append(("%s: skills/%s/SKILL.md exists" % (command, skill), path))
        continue
    text = open(path, encoding="utf-8").read()
    match = re.match(r"---\r?\n(.*?)\r?\n---\r?\n", text, re.S)
    name = re.search(r"^name: *(\S+)", match.group(1), re.M) if match else None
    if not name or name.group(1) != skill:
        problems.append(("%s: frontmatter name is %s" % (command, skill), name.group(1) if name else "missing"))

# 3. the catalog covers every skill except rune, which is a joke and has no command.
on_disk = {d for d in os.listdir(rel("skills"))
           if os.path.isfile(rel("skills", d, "SKILL.md"))} - {"rune"}
listed = {entry.get("skill") for entry in catalog}
if on_disk != listed:
    problems.append(("catalog matches skills/ minus rune",
                     "missing %s, extra %s" % (sorted(on_disk - listed), sorted(listed - on_disk))))

# 4. Codex is installed from this repo, so its skills path must exist as written.
try:
    codex = json.load(open(rel(".codex-plugin", "plugin.json")))
    skills = codex.get("skills")
    if not skills or not os.path.isdir(os.path.normpath(rel(skills))):
        problems.append(("codex plugin.json skills path exists", str(skills)))
except Exception as error:
    problems.append(("codex plugin.json parses", str(error)))

if not problems:
    print("ok\tcatalog: 6 commands, each with its skill and frontmatter")
for name, detail in problems:
    print("FAIL\t%s\t%s" % (name, detail))
PY
)"
while IFS="$(printf '\t')" read -r st name err; do
  [ -n "$st" ] || continue
  if [ "$st" = ok ]; then echo "  ok   $name"; else echo "  FAIL $name: $err"; fail=1; fi
done <<EOF
$catalog_out
EOF

echo "== the example config's test profile runs one subscription model =="
resolved="$(MULTI_CONFIG="$TREE/config.example.toml" python3 "$TREE/scripts/config.py" resolve --backend test 2>&1 || true)"
say "resolves to exactly one line" "$(printf '%s\n' "$resolved" | grep -c .)" "1"
say "and that line is the smoke-test model" \
  "$(printf '%s\n' "$resolved" | grep -c 'opencode-go/deepseek-v4\.1-flash')" "1"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
