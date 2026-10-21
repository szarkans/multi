#!/usr/bin/env python3
"""PreToolUse hook for the agy reviewer: deny by default.

agy has no read-only mode of its own: in print mode it writes files without
asking, `--mode plan` is a prompt wrapper the model may ignore, and
`toolPermission = "strict"` ends the turn with an EMPTY answer on the first
refused call (all measured 2026-10-21). A hook "deny" is returned to the model
as a reason and the turn goes on, so this hook is the read-only guarantee.
agy has no grep or list tool, only read_file and run_command, so one
read-only shell command per call is let through. Any error here is a deny.
"""
import json
import os
import re
import shlex
import sys

READ_TOOLS = ("read_file", "view_file", "list_dir", "grep_search", "find_by_name",
              "view_file_outline", "view_code_item")
SHELL_HINT = ("read-only reviewer: shell allows ONE read-only command (ls, cat, head, tail, wc, "
              "grep, find, stat, git diff/log/show/status/grep/ls-files/ls-tree/blame) on paths inside "
              "the repository, with no pipes, redirects, ;, &&, $() or backticks. The working "
              "directory is already the repository.")
OUTSIDE = "read-only reviewer: only files inside the repository are readable"
SECRET = "read-only reviewer: .env files are not readable"
# rg (--pre, --hostname-bin) and file (-C) can run or write, so they are not here.
PLAIN = ("ls", "cat", "head", "tail", "wc", "grep", "pwd", "stat")
FIND_WRITES = ("-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls")
GIT_READS = ("diff", "log", "show", "status", "grep", "ls-files", "ls-tree", "blame")
# git takes any unambiguous prefix of a long option, so "--open-f" is checked as a prefix.
GIT_DANGER = ("output", "ext-diff", "open-files-in-pager", "no-index", "textconv", "exec")


def is_secret(path):
    base = os.path.basename(path).lower()
    return (base == ".env" or base.endswith(".env") or base.startswith(".env.")) and base != ".env.example"


def inside(path, roots):
    real = os.path.realpath(path)
    return any(real == r or real.startswith(r.rstrip(os.sep) + os.sep) for r in map(os.path.realpath, roots))


def path_problem(value, roots, shell=False):
    """A reason to refuse this argument as a path, or None. Relative paths stay in the cwd unless they climb."""
    value = value.split("=", 1)[-1] if value.startswith("-") else value
    if is_secret(value):
        return SECRET
    if value.startswith("~") or ".." in value.split("/"):
        return OUTSIDE
    # A shell argument may be a grep pattern like "/api/v1": only a path that exists is a path.
    if os.path.isabs(value) and not inside(value, roots) and (not shell or os.path.lexists(value)):
        return OUTSIDE
    return None


def git_ok(argv):
    if len(argv) < 2 or argv[1] not in GIT_READS:
        return False
    for a in argv[2:]:
        if a.startswith("--"):
            name = a[2:].split("=", 1)[0]
            if name and any(d.startswith(name) for d in GIT_DANGER):
                return False
        elif a.startswith("-") and "O" in a:  # git grep -O<pager>, also inside a cluster like -nOsh
            return False
    return True


def decide(call, roots):
    name = call.get("name", "")
    args = call.get("args") or {}
    if not isinstance(args, dict):
        return "deny", "read-only reviewer: unreadable tool arguments"
    if name in READ_TOOLS:
        # Every string argument is checked, so a renamed path key cannot slip past.
        for v in args.values():
            if isinstance(v, str):
                why = path_problem(v, roots)
                if why:
                    return "deny", why
            elif not isinstance(v, (int, float, bool)) and v is not None:
                return "deny", "read-only reviewer: unreadable tool arguments"
        return "allow", ""
    if name != "run_command":
        return "deny", "read-only reviewer: only reading files and single read-only shell commands are allowed"
    cmd = args.get("CommandLine", "")
    if not isinstance(cmd, str) or re.search(r"[;&|<>`$\n\\()]", cmd):
        return "deny", SHELL_HINT
    try:
        argv = shlex.split(cmd)
    except ValueError:
        return "deny", SHELL_HINT
    if not argv:
        return "deny", SHELL_HINT
    for a in argv[1:]:
        why = path_problem(a, roots, shell=True)
        if why:
            return "deny", why if why == SECRET else SHELL_HINT
    prog = argv[0]
    if prog == "tail" and any(a.startswith("--f") or (a.startswith("-") and not a.startswith("--") and ("f" in a or "F" in a)) for a in argv[1:]):
        return "deny", SHELL_HINT  # tail -f never returns
    if prog in PLAIN:
        return "allow", ""
    if prog == "find" and not any(a in FIND_WRITES for a in argv):
        return "allow", ""
    if prog == "git" and git_ok(argv):
        return "allow", ""
    return "deny", SHELL_HINT


def main():
    try:
        payload = json.load(sys.stdin)
        call = payload.get("toolCall") or {}
        roots = [p for p in payload.get("workspacePaths") or [] if isinstance(p, str) and os.path.isabs(p)]
        decision, reason = decide(call, roots) if isinstance(call, dict) and call else ("deny", "unreadable tool call")
    except Exception:
        decision, reason = "deny", "read-only reviewer: unreadable tool call"
    out = {"decision": decision}
    if reason:
        out["reason"] = reason
    print(json.dumps(out))


if __name__ == "__main__":
    main()
