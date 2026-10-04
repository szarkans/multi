#!/usr/bin/env bash
# Checks what the OpenCode participant's bash may run (opencode-readonly.json),
# by evaluating each command the way OpenCode does: patterns are wildcards
# (* any run of characters, ? one), and the LAST matching rule wins
# (opencode.ai/docs/permissions). No CLI, no network.
#
# Why (#43): OpenCode applies the repo boundary (external_directory) to its
# read tools, not to bash. `head *` let a participant read any file on the
# disk -- .env files and multi's own providers.env included (seen live
# 2026-10-04). Reading stays with the read/grep/glob/list tools.
#
#   bash scripts/test-opencode-readonly.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

python3 - "$HERE/opencode-readonly.json" <<'PY'
import json, re, sys
rules = json.load(open(sys.argv[1]))["agent"]["multi-readonly"]["permission"]["bash"]
def decide(cmd):
    verdict = None
    for pat, action in rules.items():
        rx = "^" + "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in pat) + "$"
        if re.match(rx, cmd, re.S):
            verdict = action
    return verdict or "deny"
deny = [
    "head -100 /home/u/.config/multi/providers.env", "tail -n 5 /home/u/project/.env",
    "grep -r API_KEY /home/u", "wc -c /etc/passwd", "stat /home/u/.ssh/id_rsa",
    "ls /home/u", "ls -la /home/u/.ssh", "cat README.md",
    "git diff --no-index /home/u/.env /dev/null", "git -C /home/u/other log -p",
    "git -c diff.external=/tmp/x diff", "git --git-dir=/home/u/other/.git log",
    "git --work-tree=/home/u status", "git log --output=/tmp/x", "git status > /tmp/x",
    # Without a revision and with a path outside the work tree, git diff turns
    # into --no-index on its own, inside a repo and out (snapshots have no .git).
    "git diff /dev/null /home/u/.env", "git diff README.md ../../../home/u/.env",
    "git diff HEADER.md /home/u/.env", "git diff main.py /home/u/.env",
    "git diff --stat /dev/null /home/u/.env",
    # A rev-looking prefix is not a revision: the reviewed tree may hold a file
    # named HEAD~leak, and two paths still mean --no-index.
    "git diff HEAD~leak /home/u/.env", "git diff HEAD^x /home/u/.env", "git diff HEAD~1",
    # Flags that take a FILE and read it: blame prints it whole, grep uses it
    # as patterns (seen live 2026-10-04: --contents printed a file outside).
    "git blame --contents=/home/u/.env -- README.md", "git blame --contents /home/u/.env a.py",
    "git blame a.py", "git grep -f /home/u/.env -- .", "git grep --file=/home/u/.env",
    "git grep -n -f /home/u/.env", "git grep -nf /home/u/.env", "git grep -f/home/u/.env",
    # git grep is gone altogether: short flags bundle (-nf FILE), so no pattern
    # can pin -f down. The grep tool searches the repo instead.
    "git grep -n foo",
]
allow = ["pwd", "ls", "git status", "git status --short", "git diff", "git diff HEAD",
         "git diff --cached", "git diff --staged --stat", "git diff --stat",
         "git log -5 --oneline", "git show HEAD", 
         "git ls-files", "git rev-parse HEAD"]
bad = [c for c in deny if decide(c) != "deny"] + [c for c in allow if decide(c) != "allow"]
for c in deny:
    print(("ok   denied:  " if decide(c) == "deny" else "FAIL allowed: ") + c)
for c in allow:
    print(("ok   allowed: " if decide(c) == "allow" else "FAIL denied:  ") + c)
print("ALL PASS" if not bad else "FAILURES")
sys.exit(1 if bad else 0)
PY
