#!/usr/bin/env python3
"""Pull the idea list out of one diverge branch's output file.

Codex writes clean JSON. OpenCode writes a terminal transcript: ANSI escapes,
a `> build · <model>` header, sometimes tool calls before the answer. Both go
through here so a branch that produced nothing is reported as nothing instead
of being quietly dropped or hallucinated back in.

    parse-branch.py "$RUN/adhd-f2-codex.txt" "$RUN/adhd-f3-opencode.txt"
"""
import json, re, sys

def parse(path):
    try:
        raw = open(path, encoding="utf-8", errors="replace").read()
    except FileNotFoundError:
        return None, "NO FILE"
    txt = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw)
    if not txt.strip():
        return None, "EMPTY"
    for block in reversed(re.findall(r"\[\s*\{.*?\}\s*\]", txt, re.S)):
        try:
            return json.loads(block), None
        except ValueError:
            continue
    return None, "NO JSON ARRAY: " + txt.strip()[:120].replace("\n", " ")

if __name__ == "__main__":
    bad = 0
    for path in sys.argv[1:]:
        ideas, err = parse(path)
        if err:
            print(f"{path}: {err}"); bad = 1; continue
        print(f"{path}: {len(ideas)} ideas")
        for i in ideas:
            print("   -", str(i.get("text", ""))[:110])
    sys.exit(bad)
