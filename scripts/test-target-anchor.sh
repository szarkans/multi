#!/usr/bin/env bash
# The review target is whatever --repo says, never the process's cwd. The skill
# runs probe/collect/ask in separate bash blocks, and cwd resets to the session
# checkout between them; when the real target is a different worktree the
# reviewers used to read the wrong tree and agree on an empty diff — silently.
# So every anchor must obey an explicit --repo, and a linked worktree (the exact
# case that bit) must resolve to itself, not to its parent checkout.
#
#   bash scripts/test-target-anchor.sh
set -uo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Own MULTI_HOME: the machine's real config.toml and providers.env must not shape this test.
export MULTI_HOME="$TMP/h"; mkdir -p "$MULTI_HOME"
fail=0
ok(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
# Substring test via case, not `printf | grep`: under pipefail a grep that
# matches early closes the pipe, printf takes SIGPIPE, and the pipeline's exit
# flips — a real match could be reported as "ok". case has no pipe and no such
# trap. Quoting "$3" in the pattern keeps it a literal, not a glob.
has(){ case "$2" in *"$3"*) echo "  ok   $1" ;; *) echo "  FAIL $1: '$3' not in output"; fail=1 ;; esac; }
hasnt(){ case "$2" in *"$3"*) echo "  FAIL $1: '$3' leaked into output"; fail=1 ;; *) echo "  ok   $1" ;; esac; }

git_q(){ git -c user.email=t@t -c user.name=t "$@"; }

# --- Session checkout A (the process cwd) and a separate target B ----------
A="$TMP/session-A"; mkdir -p "$A"
( cd "$A" && git init -q && echo a > f.txt && git_q add -A && git_q commit -qm init ) >/dev/null

B="$TMP/target-B"; mkdir -p "$B/src"
( cd "$B" && git init -q \
    && printf 'nested marker BBB\n' > src/AGENTS.md \
    && echo x > src/app.txt && git_q add -A && git_q commit -qm init \
    && echo changed >> src/app.txt ) >/dev/null   # uncommitted change under src/

echo "== probe anchors to --repo, not cwd =="
out="$(cd "$A" && bash "$HERE/probe.sh" --repo "$B" 2>&1)"
has "probe repo line names the target" "$out" "repo: $B"
hasnt "probe does not name the session checkout" "$out" "repo: $A"

echo "== collect-context anchors to --repo =="
# From cwd A, ask for B's uncommitted change: B's nested AGENTS.md must surface.
outB="$(cd "$A" && bash "$HERE/collect-context.sh" --repo "$B" --diff uncommitted 2>/dev/null)"
has "collect sees the target's nested guidance" "$outB" "src/AGENTS.md"
# Same command pointed at A (no such file) must not invent it.
outA="$(cd "$A" && bash "$HERE/collect-context.sh" --repo "$A" --diff uncommitted 2>/dev/null)"
hasnt "collect pointed at cwd does not see B" "$outA" "src/AGENTS.md"

echo "== a LINKED worktree resolves to itself, not its parent (the #13 case) =="
W="$TMP/wt"
( cd "$A" && git_q worktree add -q "$W" -b wt-branch ) >/dev/null 2>&1
outW="$(cd "$A" && bash "$HERE/probe.sh" --repo "$W" 2>&1)"
has "probe names the worktree root" "$outW" "repo: $W"
hasnt "probe does not fall back to the parent checkout" "$outW" "repo: $A "

echo "== review-prompt tells models WHERE to run git =="
pr="$(bash "$HERE/review-prompt.sh" --repo "$B" --target "the change in B" --diff uncommitted 2>&1)"
has "prompt carries a cd into the target before git" "$pr" "cd $B && git diff"
# The committed-diff branch offers `git show` as an alternative — it must carry
# the cd too, or a reviewer that takes it reads the wrong tree.
prc="$(bash "$HERE/review-prompt.sh" --repo "$B" --target "x" --diff 'HEAD~1..HEAD' 2>&1)"
has "git diff alternative is anchored"  "$prc" "cd $B && git diff HEAD~1..HEAD"
has "git show alternative is anchored"  "$prc" "cd $B && git show HEAD~1..HEAD"
# A repo path with a space/quote must NOT reach the command as a raw, splittable
# path — %q escapes it. The raw form must be absent; the escaped form present.
sp="$TMP/dir with space"; mkdir -p "$sp"
prs="$(bash "$HERE/review-prompt.sh" --repo "$sp" --target "x" --diff uncommitted 2>&1)"
hasnt "raw spaced path is not emitted" "$prs" "cd $sp && git diff"
has   "spaced path is shell-escaped"   "$prs" 'dir\ with\ space'

echo "== ask.sh runs the backend in --repo, not cwd =="
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/opencode" <<EOF
#!/usr/bin/env bash
# record the --dir we were handed, then emit a minimal json answer
d=""; while [ \$# -gt 0 ]; do [ "\$1" = "--dir" ] && { d="\$2"; shift 2; continue; }; shift; done
printf 'DIR=%s\n' "\$d" >> "$TMP/opencode-dir.log"
printf '{"parts":[{"type":"text","text":"No issues found."}]}\n'
EOF
chmod +x "$STUB/opencode"
RUN="$TMP/run"; mkdir -p "$RUN"
PATH="$STUB:$PATH" \
  bash "$HERE/ask.sh" --backend opencode --model stub-model --repo "$B" \
       --question "hi" --out-prefix "$RUN/o" >/dev/null 2>&1 || true
dirlog="$( [ -f "$TMP/opencode-dir.log" ] && cat "$TMP/opencode-dir.log" || echo MISSING )"
ok "opencode was pointed at the target dir" "$dirlog" "DIR=$B"

# codex has no --dir; it must be run WITH cwd = target. Stub records its pwd.
cat > "$STUB/codex" <<EOF
#!/usr/bin/env bash
o=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && { o="\$2"; shift 2; continue; }; shift; done
pwd > "$TMP/codex-cwd.log"
[ -n "\$o" ] && printf 'No issues found.\n' > "\$o"
EOF
chmod +x "$STUB/codex"
PATH="$STUB:$PATH" \
  bash "$HERE/ask.sh" --backend codex --repo "$B" \
       --question "hi" --out-prefix "$RUN/c" >/dev/null 2>&1 || true
cwdlog="$( [ -f "$TMP/codex-cwd.log" ] && cat "$TMP/codex-cwd.log" || echo MISSING )"
ok "codex ran with cwd = target" "$cwdlog" "$B"

echo "== a RELATIVE --out-prefix survives the backend cd into --repo =="
# The codex path cd's into --repo; a relative prefix must be anchored to the
# launch cwd, not land inside the reviewed tree where the parent can't find it.
WORK="$TMP/launch"; mkdir -p "$WORK"
( cd "$WORK" && PATH="$STUB:$PATH" \
    bash "$HERE/ask.sh" --backend codex --repo "$B" \
         --question "hi" --out-prefix "rel/o" >/dev/null 2>&1 ) || true
ok "relative output landed under launch cwd, not the target" \
   "$([ -s "$WORK/rel/o-codex.txt" ] && echo here || echo lost)" "here"
ok "nothing was written into the reviewed tree" \
   "$([ -e "$B/rel" ] && echo polluted || echo clean)" "clean"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $fail
