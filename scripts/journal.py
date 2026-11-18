#!/usr/bin/env python3
"""The run journal: one permanent record per ask.sh run, kept across /tmp sweeps.

    journal.py <run-dir> [--prefix NAME]   archive a run and upsert its index row
    journal.py --stats [--journal DIR]     per-model scoreboard from the index
    journal.py --path                      where the journal lives

Why it exists: a run's files sit in /tmp/multi and are swept after a week, so
"which model actually earns its place" could never be answered from history.
The journal keeps two things per run:

    $JOURNAL/<run>__<prefix>/   the run's files (answers, sidecars, prompt,
                                diffs, reports) — everything but snapshots
                                and live markers, which are reproducible junk
    $JOURNAL/index.jsonl        one JSON object per (run_dir, prefix): who ran,
                                real model after fallbacks, status and reason,
                                seconds, tokens (per source that reports them),
                                findings parsed out of the answer

ask.sh calls this at the end of every run (best-effort, failures swallowed);
the review skill calls it again after writing report.md, so the judge's
verdict lands in the same archive. Re-running is safe: an index row is keyed
on (run_dir, prefix) and replaced, not appended.

Token sources differ per backend, and the record says which one was used:
  opencode/kilo     <out>.jsonl step_finish events (input/output/reasoning/
                    cache read+write, cost)
  codex             "tokens used\nN" in <out>.log — a single total only
  claude-headless   the child's Claude Code transcript, found via <out>.sid:
                    per-message usage summed over distinct message ids
  gemini/agy/devin  nothing is reported — tokens stay null, honestly
"""
import fcntl
import json
import os
import re
import shutil
import sys
import time

INDEX = "index.jsonl"

# The roster's own files plus every per-backend answer and sidecar a run can
# leave. *.running and *.lock are transient state, never archived; snapshot
# dirs and .kilo-training are skipped by shape (dirs, and the name).
SHARED_FILES = ("copy-path", "ctx.md", "ask.log", "report.md")


def journal_dir():
    d = os.environ.get("MULTI_JOURNAL_DIR")
    if d:
        return d
    home = os.environ.get("MULTI_HOME") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "multi")
    return os.path.join(home, "journal")


def transcript_bases():
    # claude-headless children write under the isolated child-home; a
    # login-mode "claude" backend writes under the CLAUDE_CONFIG_DIR the
    # runner pins it to — MULTI_LOGIN_CLAUDE_HOME, default ~/.claude. Honor
    # the same override here, or the tokens never reach the journal.
    yield os.path.join(child_home(), "projects")
    yield os.path.join(
        os.environ.get("MULTI_LOGIN_CLAUDE_HOME")
        or os.path.join(os.path.expanduser("~"), ".claude"), "projects")


def child_home():
    h = os.environ.get("MULTI_CHILD_HOME")
    if h:
        return h
    home = os.environ.get("MULTI_HOME") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "multi")
    return os.path.join(home, "child-home")


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def read_lines(path):
    return read(path).splitlines()


def roster(prefix_path):
    """<prefix>.run -> (ordered suffixes, {suffix: seconds})."""
    names, secs = [], {}
    for line in read_lines(prefix_path + ".run"):
        f = line.split()
        if len(f) == 1 and f[0] not in names:
            names.append(f[0])
        elif len(f) >= 2 and f[1].isdigit():
            secs[f[0]] = int(f[1])
    return names, secs


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ValueError, OSError):
        return False


def backend_status(out):
    """ok / failed / running / absent + the reason line when there is one."""
    dead = out + ".dead"
    if os.path.exists(dead):
        reason = next((l for l in read_lines(dead) if l.strip()), "")
        return "failed", reason or None
    running = out + ".running"
    if os.path.exists(running):
        f = read(running).split()
        if f and pid_alive(f[0]):
            return "running", None
        return "failed", "ended without an answer and without a marker (killed mid-run?)"
    if os.path.exists(out) and os.path.getsize(out) > 0:
        return "ok", None
    return "absent", None


# --- model actually run -------------------------------------------------
# A pinned or first-choice model is what was configured; the interesting
# number belongs to what answered. Sources, strongest first.
def model_used(txt, log, name):
    m = re.search(r"— fell back to (\S+)", txt)
    if m:
        return m.group(1)
    m = re.search(r"^## (\S+) — \d+ tool call", txt, re.M)  # opencode report header
    if m:
        return m.group(1)
    m = re.search(r"^\[multi\] answered by \S+ model (\S+)", txt, re.M)  # headless success tail
    if m:
        return m.group(1)
    cand = None
    for m in re.finditer(r"^\[multi\] (\S+) model (\S+)", log, re.M):
        if m.group(1) == name or name in (m.group(1),):
            cand = m.group(2)
    return cand


# --- tokens per backend type --------------------------------------------
def tokens_opencode(raw_path):
    """Sum step_finish events in an opencode/kilo --format json capture."""
    t = {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}
    cost, calls, seen = 0.0, 0, set()
    try:
        for line in open(raw_path, "r", encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            part = ev.get("part") or {}
            if ev.get("type") == "step_finish" and part.get("id") not in seen:
                seen.add(part.get("id"))
                tk = part.get("tokens") or {}
                t["input"] += tk.get("input") or 0
                t["output"] += tk.get("output") or 0
                t["reasoning"] += tk.get("reasoning") or 0
                cache = tk.get("cache") or {}
                t["cache_read"] += cache.get("read") or 0
                t["cache_write"] += cache.get("write") or 0
                c = part.get("cost")
                if isinstance(c, (int, float)):
                    cost += c
            elif ev.get("type") == "tool_use":
                calls += 1
    except OSError:
        return None, None, 0
    if not seen and not calls:
        return None, None, 0
    return t, round(cost, 6), calls


def tokens_codex(log):
    m = re.search(r"tokens used\s*\n\s*([\d,]+)", log)
    if not m:
        m = re.search(r"tokens used[^\d]*([\d,]+)", log)
    return {"total": int(m.group(1).replace(",", ""))} if m else None


def tokens_headless(out):
    """The child claude transcript, found through the sid sidecar, carries
    full per-message usage. Entries repeat on stream flushes, so dedupe on
    message.id before summing."""
    sid = read(out + ".sid").strip()
    if not sid:
        return None
    path = None
    for base in transcript_bases():
        try:
            dirs = os.listdir(base)
        except OSError:
            continue
        for d in dirs:
            p = os.path.join(base, d, sid + ".jsonl")
            if os.path.isfile(p):
                path = p
                break
        if path:
            break
    if not path:
        return None
    t = {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}
    seen = set()
    for line in read_lines(path):
        if '"usage"' not in line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        msg = ev.get("message") or {}
        u = msg.get("usage")
        if not isinstance(u, dict):
            continue
        mid = msg.get("id") or ev.get("uuid")
        if mid in seen:
            continue
        seen.add(mid)
        t["input"] += u.get("input_tokens") or 0
        t["output"] += u.get("output_tokens") or 0
        t["cache_read"] += u.get("cache_read_input_tokens") or 0
        t["cache_write"] += u.get("cache_creation_input_tokens") or 0
        det = u.get("output_tokens_details") or {}
        t["reasoning"] += det.get("thinking_tokens") or 0
    return t if seen else None


FINDING = re.compile(
    r"^\s*(?:\d+[.)]\s*)?(?:[\[\(]?[^\s|\]]*[\]\)]?\s+)?"     # optional bullet / author tag
    r"`?([A-Za-z0-9_./\-]+):(\d+)`?\s*\|\s*"                  # file:line |
    r"(CRITICAL|HIGH|MEDIUM|LOW)\b[^|]*\|\s*(.+)$", re.I | re.M)


def findings(txt):
    """Parse unified-format findings out of an answer. For opencode reports
    only the '## Answer' section is the model's text; everything above it is
    the tool-call list, which can quote finding-shaped lines from files."""
    m = re.search(r"^## Answer\s*$", txt, re.M)
    if m:
        txt = txt[m.end():]
    out = []
    for fm in FINDING.finditer(txt):
        sev = fm.group(3).upper()
        claim = re.sub(r"\s+", " ", fm.group(4)).strip()
        # Drop our own service lines before they count as findings.
        if claim.startswith("[multi]"):
            continue
        out.append({"file": fm.group(1), "line": int(fm.group(2)),
                    "severity": sev, "claim": claim[:400]})
    return out


def trains(path):
    rows = []
    for line in read_lines(path):
        f = line.split(None, 1)
        if len(f) == 2 and f[0] in ("yes", "no", "unknown"):
            rows.append({"model": f[1].strip(), "verdict": f[0]})
    return rows


def collect_backend(run_dir, prefix, suffix, secs):
    out = os.path.join(run_dir, "%s-%s.txt" % (prefix, suffix))
    txt, log = read(out), read(out + ".log")
    status, reason = backend_status(out)
    # The suffix is the backend's CONFIG name (openrouter, my-router...), not
    # its type — so token sources are tried by the artifacts they leave:
    # a .jsonl capture means an opencode-family runner, a .sid means a
    # claude-headless child transcript, "tokens used" in stderr means codex.
    # gemini/agy/devin leave none of those and their tokens stay null.
    name = re.sub(r"-\d+$", "", suffix)
    model = model_used(txt, log, name)
    tokens, cost, calls = None, None, None
    if os.path.isfile(out + ".jsonl"):
        tokens, cost, calls = tokens_opencode(out + ".jsonl")
    if tokens is None:
        tokens = tokens_codex(log)
    if tokens is None:
        tokens = tokens_headless(out)
    if model is None:
        m = re.search(r"^\[multi\] \S+ model (\S+)", log, re.M)
        model = m.group(1) if m else None
    if tokens is not None and "total" not in tokens:
        tokens["total"] = sum(v for v in tokens.values() if isinstance(v, int))
    found = findings(txt) if status == "ok" else []
    tr = trains(out + ".trains")
    attempted = []
    for row in tr:
        if row["model"] not in attempted:
            attempted.append(row["model"])
    if not attempted and model:
        attempted = [model]
    return {
        "suffix": suffix, "backend": name, "model": model, "attempted": attempted,
        "status": status, "reason": reason, "seconds": secs.get(suffix),
        "tokens": tokens, "cost": cost, "calls": calls,
        "trains": tr, "findings": found, "findings_count": len(found),
    }


def archive(run_dir, prefix, dest):
    """Copy the run's files into the journal. Files only — snapshot dirs and
    other tree copies are reproducible and huge, and stay behind."""
    os.makedirs(dest, exist_ok=True)
    copied = []
    base = os.path.basename(prefix)
    for name in sorted(os.listdir(run_dir)):
        src = os.path.join(run_dir, name)
        if not os.path.isfile(src):
            continue
        if name in SHARED_FILES or name.endswith((".prompt.md", ".diff", ".manifest")):
            pass
        elif name.startswith(base + ".") or name.startswith(base + "-"):
            if name.endswith((".running", ".lock", ".kilo-training")) or ".tmp" in name:
                continue
        else:
            continue
        shutil.copy2(src, os.path.join(dest, name))
        copied.append(name)
    # The claude-headless transcripts belong to the run too — copy each .sid's
    # file next to the answers so the archive survives child-home cleanup.
    for name in os.listdir(dest):
        if not name.endswith(".sid"):
            continue
        sid = read(os.path.join(dest, name)).strip()
        if not sid:
            continue
        for base in transcript_bases():
            try:
                dirs = os.listdir(base)
            except OSError:
                continue
            found = False
            for d in dirs:
                p = os.path.join(base, d, sid + ".jsonl")
                if os.path.isfile(p):
                    shutil.copy2(p, os.path.join(dest, name[:-4] + ".transcript.jsonl"))
                    copied.append(name[:-4] + ".transcript.jsonl")
                    found = True
                    break
            if found:
                break
    return sorted(copied)


def merge_verdict(backends, verdict):
    """Attach verdict buckets to backend findings and keep a per-backend
    bucket tally. author -> backend: the inventory names either the suffix
    (codex, opencode-2) or the model that ran (hy4, glm-5.2:free)."""
    if not isinstance(verdict, dict):
        return
    vf = verdict.get("findings")
    if not isinstance(vf, list):
        return
    for b in backends:
        b["buckets"] = {}
    def be_find_backend(author):
        a = (author or "").strip().strip("[]").lower()
        for b in backends:
            if b["suffix"].lower() == a or b["backend"].lower() == a:
                return b
        for b in backends:
            m = (b.get("model") or "").lower()
            if m and (m == a or m.endswith("/" + a) or a in m):
                return b
        return None
    for vf_item in vf:
        if not isinstance(vf_item, dict):
            continue
        bucket = str(vf_item.get("bucket") or "").lower()
        b = be_find_backend(vf_item.get("author"))
        if b is None or bucket not in ("corroborated", "verified", "minor", "dropped", "disagreed"):
            continue
        b["buckets"][bucket] = b["buckets"].get(bucket, 0) + 1
        # Mark the matching parsed finding, so a reader can trace it.
        for f in b.get("findings") or []:
            if f.get("bucket"):
                continue
            same_file = (f.get("file") or "").split("/")[-1] == str(vf_item.get("file") or "").split("/")[-1]
            if same_file and f.get("line") == vf_item.get("line"):
                f["bucket"] = bucket
                break
    for b in backends:
        if not b["buckets"]:
            b.pop("buckets")


def collect(run_dir, prefix, jdir):
    prefix_name = os.path.basename(prefix)
    names, secs = roster(prefix)
    if not names:
        return None
    base = os.path.basename(run_dir.rstrip("/"))
    session_id, _, slug = base.partition("--")
    # The prompt the backends were actually sent: the copy ask.sh writes, then
    # the skill's prompt file, then any single *.prompt.md in the run dir.
    prompt_file = prefix + ".prompt"
    if not os.path.isfile(prompt_file):
        cand = os.path.join(run_dir, prefix_name + ".prompt.md")
        if os.path.isfile(cand):
            prompt_file = cand
        else:
            md = [f for f in os.listdir(run_dir) if f.endswith(".prompt.md")]
            prompt_file = os.path.join(run_dir, md[0]) if len(md) == 1 else None
    prompt = read(prompt_file) if prompt_file else None
    dest = os.path.join(jdir, "%s__%s" % (base, prefix_name))
    files = archive(run_dir, prefix, dest)
    backends = [collect_backend(run_dir, prefix_name, s, secs) for s in names]
    # The judge's verdict, when the review skill wrote one: fold each finding's
    # bucket into the backend that raised it so --stats can score precision,
    # not just volume. Matching is by author (a backend suffix or the model it
    # ran) plus file+line — a loose join, because the judge rewrites claims.
    vfile = os.path.join(run_dir, "verdict.json")
    verdict = None
    if os.path.isfile(vfile):
        try:
            verdict = json.loads(read(vfile))
        except ValueError:
            verdict = None
        merge_verdict(backends, verdict)
    row = {
        "v": 1, "ts": int(time.time()),
        "session": {"id": session_id, "slug": slug},
        "run_dir": run_dir, "prefix": prefix_name,
        "prompt": prompt, "prompt_file": os.path.basename(prompt_file) if prompt_file else None,
        "archive": os.path.relpath(dest, jdir),
        "backends": backends,
        "verdict": verdict,
        "judge_report": "report.md" if "report.md" in files else None,
        "files": files,
    }
    return row


def upsert(jdir, row):
    """One row per (run_dir, prefix): a re-collect after report.md lands
    replaces the earlier row, never duplicates."""
    path = os.path.join(jdir, INDEX)
    os.makedirs(jdir, exist_ok=True)
    lock_path = os.path.join(jdir, ".lock")
    with open(lock_path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = []
        if os.path.isfile(path):
            for line in read_lines(path):
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if (r.get("run_dir"), r.get("prefix")) == (row["run_dir"], row["prefix"]):
                    continue
                rows.append(line)
        rows.append(json.dumps(row, ensure_ascii=False))
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(rows) + "\n")
        os.replace(tmp, path)
        fcntl.flock(lock, fcntl.LOCK_UN)


def median(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2 if n else None


def fmt_tokens(t):
    if not t:
        return "-"
    inp = t.get("input"); out = t.get("output"); tot = t.get("total")
    if inp is None and out is None:
        return "%s tot" % _k(tot)
    hit = (t.get("cache_read") or 0)
    base = (t.get("input") or 0) + hit
    pct = " %d%%hit" % (100 * hit / base) if base else ""
    return "%s/%s%s" % (_k(inp), _k(out), pct)


def _k(n):
    if not isinstance(n, (int, float)):
        return "?"
    return "%.1fk" % (n / 1000) if n >= 1000 else str(int(n))


def stats(jdir):
    path = os.path.join(jdir, INDEX)
    if not os.path.isfile(path):
        print("no journal yet: %s" % path)
        return 0
    per = {}
    for line in read_lines(path):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        for b in row.get("backends") or []:
            key = b.get("model") or "%s ?" % b.get("backend")
            e = per.setdefault(key, {"runs": 0, "ok": 0, "fail": 0, "secs": [],
                                     "tokens": [], "find": [], "trains": set(),
                                     "backends": set(), "cost": 0.0, "cost_n": 0,
                                     "cfm": 0, "drp": 0})
            e["runs"] += 1
            e["backends"].add(b.get("backend") or "?")
            bk = b.get("buckets") or {}
            cfm = sum(bk.get(k, 0) for k in ("corroborated", "verified", "minor"))
            drp = sum(bk.get(k, 0) for k in ("dropped", "disagreed"))
            e["cfm"] += cfm; e["drp"] += drp
            if b.get("status") == "ok":
                e["ok"] += 1
                e["find"].append(b.get("findings_count") or 0)
            elif b.get("status") == "failed":
                e["fail"] += 1
            if isinstance(b.get("seconds"), (int, float)):
                e["secs"].append(b["seconds"])
            if b.get("tokens"):
                e["tokens"].append(b["tokens"])
            if isinstance(b.get("cost"), (int, float)):
                e["cost"] += b["cost"]; e["cost_n"] += 1
            for t in b.get("trains") or []:
                e["trains"].add(t.get("verdict"))
    print("%-46s %5s %4s %5s %6s %14s %8s %10s %9s" % (
        "model", "runs", "ok", "fail", "med_s", "tokens in/out", "find/run",
        "cfm/drp", "trains"))
    for model, e in sorted(per.items(), key=lambda kv: -kv[1]["runs"]):
        s = median(e["secs"])
        tok = None
        if e["tokens"]:
            tok = {"input": median([t.get("input") for t in e["tokens"]]),
                   "output": median([t.get("output") for t in e["tokens"]]),
                   "cache_read": median([t.get("cache_read") for t in e["tokens"]]),
                   "total": median([t.get("total") for t in e["tokens"]])}
        fr = median(e["find"])
        tot = e["cfm"] + e["drp"]
        print("%-46s %5d %4d %5d %6s %14s %8s %10s %9s" % (
            model[:46], e["runs"], e["ok"], e["fail"],
            "%ds" % s if s is not None else "-",
            fmt_tokens(tok),
            ("%.1f" % fr) if fr is not None else "-",
            ("%d/%d %d%%" % (e["cfm"], e["drp"], 100 * e["cfm"] / tot)) if tot else "-",
            "/".join(sorted(e["trains"])) or "-"))
    print("\n%d journal rows, index: %s" % (
        sum(1 for l in read_lines(path) if l.strip()), path))
    print("runs that ended 'failed' count toward fail; 'running' rows are unfinished and not counted as either.")
    return 0


def main(argv):
    args = argv[1:]
    jdir = journal_dir()
    if "--journal" in args:
        i = args.index("--journal")
        jdir = args[i + 1]
        del args[i:i + 2]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if args[0] == "--path":
        print(jdir)
        return 0
    if args[0] == "--stats":
        return stats(jdir)
    run_dir = os.path.abspath(args[0])
    prefix_only = None
    if "--prefix" in args:
        i = args.index("--prefix")
        prefix_only = args[i + 1]
    if not os.path.isdir(run_dir):
        sys.stderr.write("journal.py: not a run dir: %s\n" % run_dir)
        return 2
    prefixes = [prefix_only] if prefix_only else \
        [f[:-4] for f in os.listdir(run_dir) if f.endswith(".run")]
    n = 0
    for p in prefixes:
        row = collect(run_dir, os.path.join(run_dir, p), jdir)
        if row is None:
            continue
        upsert(jdir, row)
        n += 1
    print("journal: %d run(s) recorded -> %s" % (n, jdir))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
