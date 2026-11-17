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
import glob as globlib
import json
import os
import re
import shlex
import subprocess
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


GLOB_CHARS = set("*?[]{}")
BRACE_LIMIT = 256
UNEXPANDABLE = "read-only reviewer: brace expansion too complex to verify"


def brace_expand(arg, depth=0):
    """The {a,b}, {x..y} and {x..y..s} forms a real shell expands and glob()
    does not — `cat {x,.env}` reaches .env without the literal check ever
    seeing it. Returns None when the expansion exceeds the caps: the shell
    expands what we cannot verify, and a truncated list fails OPEN.
    """
    if "{" not in arg:
        return [arg]
    if depth > 4:
        return None
    m = re.search(r"\{([^{}]*)\}", arg)
    if not m:
        return [arg]
    inner = m.group(1)
    if "," in inner:
        alts = inner.split(",")
    else:
        rng = re.fullmatch(r"(-?\d+|[A-Za-z])\.\.(-?\d+|[A-Za-z])(?:\.\.(-?\d+))?", inner)
        if not rng:
            return [arg]  # {x} without a comma or range stays literal in a shell
        lo, hi, step = rng.groups()
        step = int(step) if step else 1
        if step == 0:
            step = 1  # bash coerces a 0 step to 1: {a..z..0} is the alphabet
        lo_n = re.fullmatch(r"-?\d+", lo) and re.fullmatch(r"-?\d+", hi)
        lo_c = len(lo) == 1 and len(hi) == 1 and lo.isalpha() and hi.isalpha()
        if not (lo_n or lo_c):
            return [arg]  # bash does not mix letters and numbers in one range
        lo_i, hi_i = (int(lo), int(hi)) if lo_n else (ord(lo), ord(hi))
        step = abs(step) * (1 if hi_i >= lo_i else -1)  # {z..a} counts down too
        # Count BEFORE building: `{0..1000000000}` must not allocate the list
        # it takes to find out it is over the cap — the hook itself is a
        # memory-exhaustion target otherwise.
        if abs(hi_i - lo_i) // abs(step) + 1 > BRACE_LIMIT:
            return None
        stop = hi_i + (1 if step > 0 else -1)
        alts = [str(i) for i in range(lo_i, stop, step)] if lo_n else \
            [chr(c) for c in range(lo_i, stop, step)]
    out = []
    for a in alts:
        sub = brace_expand(arg[:m.start()] + a + arg[m.end():], depth + 1)
        if sub is None:
            return None
        out.extend(sub)
        if len(out) > BRACE_LIMIT:
            return None
    return out


def expand_glob(pat, roots):
    """Filesystem matches of one glob pattern, under every workspace root.

    Over-approximate on purpose: quoting is already stripped by shlex, so a
    regex like `.*` may be expanded as if the shell had globbed it — a false
    deny, which is the safe side for a gate. [^x] is rewritten to [!x]: bash
    accepts both for class negation, glob() only takes !.
    """
    if not any(c in pat for c in GLOB_CHARS):
        return []
    pat = pat.replace("[^", "[!")
    # POSIX classes ([[:alpha:]], [[=a=]], [[.ch.]]) expand in bash but not in
    # glob()/fnmatch — a bracket expr containing one is widened to `?`, a
    # superset of the single char the class matches: over-approximating means
    # at worst one deny too many, never a missed secret.
    pat = re.sub(r"\[[^\]]*\[:[^\]]*\][^\]]*\]", "?", pat)
    pats = [pat] if os.path.isabs(pat) else [os.path.join(r, pat) for r in roots]
    out = []
    for p in pats:
        out.extend(globlib.glob(p, recursive=True))
    return out


# Bounded walk for recursive readers: `grep -r` reads every file under its
# target, so "does this tree hold a .env?" is the question. Exceeding the bound
# fails CLOSED — a truncated scan must not read as "no secret".
WALK_LIMIT = 20000


def tree_has_secret(d, follow, roots):
    """`grep -r` does not follow symlinked dirs, `grep -R` does — the walk
    mirrors that, with a visited set against link loops when following.
    Under -R a symlink inside the tree is dereferenced wherever it points,
    so any link resolving OUTSIDE the workspace is itself the leak:
    `sub/etc -> /etc` searched whole."""
    seen = 0
    visited = set()
    for root, dirs, files in os.walk(d, followlinks=follow):
        if follow:
            rp = os.path.realpath(root)
            if rp in visited:
                dirs[:] = []
                continue
            visited.add(rp)
            for x in dirs:
                p = os.path.join(root, x)
                if os.path.islink(p) and not inside(os.path.realpath(p), roots):
                    return True
        else:
            dirs[:] = [x for x in dirs if not os.path.islink(os.path.join(root, x))]
        seen += 1
        if seen > WALK_LIMIT:
            return True
        for f in files:
            if is_secret(f):
                return True
            # -R dereferences file links too: `leak -> ../.env` walks clean by
            # name while grep prints the target's content.
            if follow:
                p = os.path.join(root, f)
                if os.path.islink(p):
                    real = os.path.realpath(p)
                    if is_secret(real) or not inside(real, roots):
                        return True
    return False


def long_is(arg, *options):
    """`--foo[=x]` names one of options, by full name or unambiguous prefix —
    getopt_long accepts `grep --rec` for --recursive, same class git_ok guards."""
    if not arg.startswith("--"):
        return False
    name = arg[2:].split("=", 1)[0]
    return any(o.startswith(name) for o in options)


def grep_recursive(argv, pat_idx=None, skip=frozenset()):
    """A grep argv that reads whole directories, not just named files.
    pat_idx/skip mark the pattern operand and -e/--regexp values — `grep -e
    '-r' dir` searches for the literal string -r, it does not recurse."""
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--":
            break
        if i == pat_idx or i in skip:
            i += 1
            continue
        if a.startswith("--"):
            if long_is(a, "recursive", "dereference-recursive"):
                return True
            if long_is(a, "directories"):
                _, eq, val = a.partition("=")
                if (eq and val in ("r", "recurse")) or \
                        (not eq and i + 1 < len(argv) and argv[i + 1] in ("r", "recurse")):
                    return True
        elif a.startswith("-") and len(a) > 1:
            if "r" in a[1:] or "R" in a[1:]:
                return True
            # -d <action>: a trailing d consumes the next argument
            if a.endswith("d") and "d" in a[1:] and \
                    i + 1 < len(argv) and argv[i + 1] in ("r", "recurse"):
                return True
        i += 1
    return False


# Options that consume a separate value — walked past when locating grep's
# pattern operand. The pattern itself comes via -e/-f/--regexp/--file, or the
# first positional argument.
# Optional-argument options (--color, --colour) are NOT here: they take a
# value only via `=`, never the next argv — `grep --color KEY .env` has KEY as
# the pattern and .env as the file, and treating KEY as the option's value
# freed .env from the path checks.
GREP_LONG_VALUE = ("exclude", "exclude-dir", "exclude-from", "include", "label",
                   "max-count", "after-context", "before-context", "context",
                   "binary-files", "devices", "directories",
                   "regexp", "file")


def grep_operands(argv):
    """(pattern index, path operand indices, pattern-value indices, attached
    values) — which argv entries are grep's pattern, its path operands, values
    that are regex data not files, and values glued inside a flag argument
    (`-f.env`, `--file=.env`) that a path check must see WITHOUT the flag.
    -e/--regexp values are patterns and are exempted via the third element;
    -f/--file values ARE files and stay checked, attached or not.
    """
    pos = []
    via_e = False
    skip = set()
    attached = {}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--":
            pos.extend(range(i + 1, len(argv)))
            break
        if a.startswith("--"):
            if long_is(a, "regexp"):
                via_e = True
                if "=" in a:
                    skip.add(i)
                else:
                    i += 1
                    skip.add(i)  # the pattern is the next argument
            elif long_is(a, "file"):
                via_e = True
                if "=" not in a:
                    i += 1  # the pattern FILE is the next arg — still a path
            elif "=" not in a and long_is(a, *GREP_LONG_VALUE):
                i += 1  # the value is the next argument
        elif a.startswith("-") and len(a) > 1:
            for j, ch in enumerate(a[1:], 1):
                if ch == "e":
                    via_e = True
                    skip.add(i if j < len(a) - 1 else i + 1)
                    if j == len(a) - 1:
                        i += 1  # -e at cluster end consumes the next arg
                    break
                if ch == "f":
                    via_e = True
                    if j == len(a) - 1:
                        i += 1  # -f's file is the next arg — still a path
                    else:
                        attached[i] = a[j + 1:]  # -f.env: the file is glued on
                    break
                if ch in "mABCDdg" and j == len(a) - 1:
                    i += 1  # a value-taking flag at cluster end consumes next
                    break
        else:
            pos.append(i)
        i += 1
    if via_e:
        return None, pos, skip, attached
    return (pos[0] if pos else None), pos[1:], skip, attached


def grep_deref(argv, skip=frozenset()):
    """-R/--dereference-recursive follows symlinked directories; -r does not.
    skip marks -e/--regexp values: `grep -e '-R' dir` is a literal search."""
    for i, a in enumerate(argv):
        if i == 0 or i in skip:
            continue
        if a == "--":
            break
        if a.startswith("--"):
            if long_is(a, "dereference-recursive"):
                return True
        elif a.startswith("-") and "R" in a[1:]:
            return True
    return False


def grep_dirs(argv, roots, operands=None):
    """Directories a recursive grep would actually open.

    Every operand that resolves to a directory is walked — path operands, glob
    targets the shell expands, flag values too. Checking one dir too many is a
    rare false deny; missing a real target is the hole. With no path operand
    at all the command reads the cwd — the roots — whatever the flag list was.
    """
    pat_idx, paths, skip, attached = operands or grep_operands(argv)
    dirs = set()
    for idx, a in enumerate(argv):
        if idx == 0 or idx == pat_idx or idx in skip:
            continue
        val = (attached or {}).get(idx, a)
        pats = brace_expand(val)
        if pats is None:
            return list(roots)  # unverifiable expansion — walk everything
        for pat in pats:
            for m in expand_glob(pat, roots) or [pat]:
                cands = [m] if os.path.isabs(m) else [os.path.join(r, m) for r in roots]
                for d in cands:
                    if os.path.isdir(d):
                        dirs.add(os.path.normpath(d))
    if not dirs and not paths:
        return list(roots)
    return list(dirs)


def git_probe(r, *args):
    """One read-only git query against one root. None on ANY failure — a probe
    that cannot run cannot vouch for the argument, so callers treat None as
    'unverifiable', which resolves to deny unless another root answers clean.
    core.quotePath=false: without it a committed `café.env` arrives C-quoted
    and is_secret never sees the .env tail."""
    try:
        out = subprocess.run(["git", "-C", r, "-c", "core.quotePath=false", *args],
                             capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return out.stdout if out.returncode == 0 else None


def git_blob_sha(sha, roots):
    """An object name that resolves to a blob — `git show <sha>` prints its
    content whatever path it was committed under, .env included. Any
    unambiguous abbreviation resolves, so every hex-ish arg is probed, not
    just canonical 40-hex (git ls-tree hands the model the full list); peel
    suffixes like `<sha>^{blob}` name the same blob and are probed verbatim."""
    if not re.fullmatch(r"[0-9a-fA-F]{4,40}(?:\^\{?[A-Za-z]*\}?)*", sha):
        return False
    for r in roots:
        if git_probe(r, "rev-parse", "--git-dir") is None:
            continue  # not a worktree — the command fails there anyway
        out = git_probe(r, "cat-file", "-t", sha)
        if out is None:
            return True  # a repo that cannot answer is unverifiable, not clean
        if out.strip() == "blob":
            return True
    return False  # no repo answered — git fails there anyway


def git_pathspec_secret(pat, roots):
    """A pathspec expands against git's index, not the filesystem — `.e*`
    reaches a committed .env the worktree no longer holds, and `-- .` or
    `HEAD:sub/` lists everything under a prefix. Literal names probe too:
    `ls-files -- sub/` answers whether a secret lives under that prefix."""
    probes = (("ls-files", "-z", "--", pat),
              ("ls-tree", "-r", "-z", "--name-only", "HEAD", "--", pat))
    for r in roots:
        if git_probe(r, "rev-parse", "--git-dir") is None:
            continue  # not a worktree — the command fails there anyway
        for probe in probes:
            out = git_probe(r, *probe)
            if out is None:
                return True  # a repo that cannot answer is unverifiable
            if any(is_secret(line) for line in out.split("\0")):
                return True
    return False  # no repo answered — git fails there anyway


def tracked_secret(roots):
    """The repo itself commits a secret file — then `git log -p`, `git show
    <commit>`, `git diff` and `git grep` print it without naming its path,
    so a content-emitting read with no scoping pathspec must be refused.
    A root that is not a git worktree contributes nothing: the command fails
    there anyway. A repo whose index cannot be listed is unverifiable —
    that is a deny, not a clean bill."""
    for r in roots:
        if git_probe(r, "rev-parse", "--git-dir") is None:
            continue
        out = git_probe(r, "ls-files", "-z")
        if out is None:
            return True
        if any(is_secret(p) for p in out.split("\0")):
            return True
    return False


def git_is_rev(arg, roots):
    """The operand names a revision or revision SET — `main`, `HEAD`,
    `A..B`, `A...B` — rather than a path that scopes the output. rev-list
    answers where rev-parse --verify fails on ranges; a name it cannot
    resolve is a path to git. A root that cannot answer contributes
    nothing: in a non-git directory the command fails anyway."""
    for r in roots:
        if git_probe(r, "rev-list", "-n", "1", arg) is not None:
            return True
    return False


def git_emits_content(argv):
    """Whether this git argv prints file CONTENT (patches, blob bodies,
    matching lines) rather than names and metadata — the difference between
    `git log` (safe) and `git log -p` (prints .env hunks). -L:func:file emits
    line history — content too."""
    sub = argv[1]
    if sub in ("diff", "show", "grep"):
        return True
    if sub == "log":
        for a in argv[2:]:
            if a == "--":
                break
            if a.startswith("--"):
                if long_is(a, "patch", "unified"):
                    return True
            elif a.startswith("-L") or (a.startswith("-") and
                                        any(c in a[1:] for c in "puU")):
                return True
    return False


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
    # A name that is not secret can still point at one: `cat leak` where
    # leak -> ../.env (or -> /etc/passwd) follows the link, so the resolved
    # path is what gets checked. Realpath on a non-existent glob/pattern
    # just normalizes it and the lexists test below still lets it pass.
    anchor = value if os.path.isabs(value) else os.path.join(roots[0], value)
    real = os.path.realpath(anchor)
    if is_secret(real):
        return SECRET
    # A shell argument may be a grep pattern like "/api/v1": only a path that exists is a path.
    if not inside(real, roots) and (not shell or os.path.lexists(real)):
        return OUTSIDE
    return None


def git_ok(argv):
    if len(argv) < 2 or argv[1] not in GIT_READS:
        return False
    # git grep flags that widen the search beyond tracked-scope reviewers get:
    # --untracked and --no-exclude-standard reach ignored .env files that the
    # index checks cannot see; --recurse-submodules reaches outside the repo.
    danger = GIT_DANGER + (("untracked", "no-exclude-standard", "recurse-submodules")
                           if argv[1] == "grep" else ())
    for a in argv[2:]:
        if a.startswith("--"):
            name = a[2:].split("=", 1)[0]
            if name and any(d.startswith(name) for d in danger):
                return False
        elif a.startswith("-") and "O" in a:  # git grep -O<pager>, also inside a cluster like -nOsh
            return False
    return True


def git_grep_operands(argv):
    """Same 4-tuple shape as grep_operands, for `git grep`: the first
    non-option arg before -- is the PATTERN (regex data, exempt from path
    checks); -e/--regexp add more patterns; -f/--file values are pattern
    FILES and stay checked; everything after -- is a pathspec operand."""
    pos = []
    via_e = False
    skip = set()
    attached = {}
    i = 2
    while i < len(argv):
        a = argv[i]
        if a == "--":
            pos.extend(range(i + 1, len(argv)))
            break
        if a.startswith("--"):
            if long_is(a, "regexp"):
                via_e = True
                if "=" in a:
                    skip.add(i)
                else:
                    i += 1
                    skip.add(i)
            elif long_is(a, "file"):
                via_e = True
                if "=" in a:
                    attached[i] = a.split("=", 1)[1]
                else:
                    i += 1
                    pos.append(i)
            elif "=" not in a and long_is(a, "threads", "max-count", "context",
                                          "after-context", "before-context"):
                i += 1  # value-taking option — its value is the next argument
        elif a.startswith("-") and len(a) > 1:
            for j, ch in enumerate(a[1:], 1):
                if ch == "e":
                    via_e = True
                    skip.add(i if j < len(a) - 1 else i + 1)
                    if j == len(a) - 1:
                        i += 1
                    break
                if ch == "f":
                    via_e = True
                    if j == len(a) - 1:
                        i += 1
                        pos.append(i)
                    else:
                        attached[i] = a[j + 1:]
                    break
                if ch in "ABCm" and j == len(a) - 1:
                    i += 1
                    break
        else:
            pos.append(i)
        i += 1
    if via_e:
        return None, pos, skip, attached
    return (pos[0] if pos else None), pos[1:], skip, attached


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
    prog = argv[0]
    if prog == "grep":
        pat_idx, paths, skip, attached = grep_operands(argv)
    elif prog == "git" and argv[1:2] == ["grep"]:
        pat_idx, paths, skip, attached = git_grep_operands(argv)
    else:
        pat_idx, paths, skip, attached = None, [], set(), {}
    for idx, a in enumerate(argv):
        if idx == 0 or idx == pat_idx or idx in skip:
            continue  # pattern operands are regex, never files to open
        a = attached.get(idx, a)  # `-f.env` hides its operand inside the flag
        why = path_problem(a, roots, shell=True)
        if why:
            return "deny", why if why == SECRET else SHELL_HINT
        pats = brace_expand(a)
        if pats is None:
            return "deny", UNEXPANDABLE
        for pat in pats:
            why = path_problem(pat, roots, shell=True)
            if why:
                return "deny", why if why == SECRET else SHELL_HINT
            for match in expand_glob(pat, roots):
                why = path_problem(match, roots, shell=True)
                if why:
                    return "deny", why if why == SECRET else SHELL_HINT
    if prog == "tail" and any(a.startswith("--f") or (a.startswith("-") and not a.startswith("--") and ("f" in a or "F" in a)) for a in argv[1:]):
        return "deny", SHELL_HINT  # tail -f never returns
    if prog in PLAIN:
        if prog == "grep" and grep_recursive(argv, pat_idx, skip):
            for d in grep_dirs(argv, roots, (pat_idx, paths, skip, attached)):
                if tree_has_secret(d, grep_deref(argv, skip), roots):
                    return "deny", SECRET
        return "allow", ""
    if prog == "find" and not any(a in FIND_WRITES for a in argv):
        return "allow", ""
    if prog == "git" and git_ok(argv):
        # REV:path and a bare blob sha both reach file content without naming
        # the file as a path argument; flag arguments like --format=x:.env
        # name no blob and are skipped. Every check runs on EACH expanded
        # word: the shell applies braces before git sees the argument, so
        # `git show {<sha>,x}` must not pass on the literal braces.
        scoped = "--" in argv[2:] and argv.index("--") + 1 < len(argv)
        for idx, a in enumerate(argv[1:], 1):
            if a == "--" or idx == pat_idx or idx in skip:
                continue
            if a.startswith("-"):
                if a.startswith("-L"):
                    # -L<n,m>:<file> emits that file's line history
                    spec = a[2:] or (argv[idx + 1] if idx + 1 < len(argv) else "")
                    _, _, tail = spec.rpartition(":")
                    if tail and (is_secret(tail) or git_pathspec_secret(tail, roots)):
                        return "deny", SECRET
                continue
            # braces apply here too: the shell turns HEAD:.en{v,} into HEAD:.env
            pats = brace_expand(a)
            if pats is None:
                return "deny", UNEXPANDABLE
            for p in pats:
                _, sep, tail = p.rpartition(":")
                if sep and (is_secret(tail) or git_pathspec_secret(tail, roots)):
                    return "deny", SECRET
                if git_blob_sha(p, roots) or git_pathspec_secret(p, roots):
                    return "deny", SECRET
        # No scoping pathspec means the whole tree is the target: `git log -p`,
        # `git show <commit>`, `git diff`, `git grep` all print every hunk —
        # including a committed .env's — without naming it once. A trailing
        # operand scopes the same way when it is a path or REV:path (already
        # probe-checked above) rather than a revision.
        if git_emits_content(argv) and not scoped and tracked_secret(roots):
            for idx, a in enumerate(argv[2:], 2):
                if a == "--" or a.startswith("-") or idx == pat_idx or idx in skip:
                    continue
                if ":" in a or not git_is_rev(a, roots):
                    scoped = True
                    break
            if not scoped:
                return "deny", SECRET
        return "allow", ""
    return "deny", SHELL_HINT


def main():
    try:
        payload = json.load(sys.stdin)
        call = payload.get("toolCall") or {}
        # No usable workspacePaths means the hook's cwd is the workspace — an
        # empty roots list would make every relative check a no-op.
        roots = [p for p in payload.get("workspacePaths") or [] if isinstance(p, str) and os.path.isabs(p)] \
            or [os.path.realpath(".")]
        decision, reason = decide(call, roots) if isinstance(call, dict) and call else ("deny", "unreadable tool call")
    except Exception:
        decision, reason = "deny", "read-only reviewer: unreadable tool call"
    out = {"decision": decision}
    if reason:
        out["reason"] = reason
    print(json.dumps(out))


if __name__ == "__main__":
    main()
