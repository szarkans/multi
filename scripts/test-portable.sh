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
for m in .claude-plugin/marketplace.json .codex-plugin/plugin.json gemini-extension.json; do
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

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
