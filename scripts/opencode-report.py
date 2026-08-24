#!/usr/bin/env python3
"""Turn `opencode run --format json` events into something a human can read.

    opencode run --pure --agent plan --format json ... > raw.jsonl
    opencode-report.py raw.jsonl --out review.txt --calls review.txt.calls

Why this exists: the default output of `opencode run` is a terminal
transcript -- ANSI colour, tool banners, and the full contents of every file
the model opened, with its actual answer buried somewhere inside. The old
reader grepped that whole thing for finding-shaped lines, which cannot tell
"the model said this" from "the model read this in a file". On 2026-08-20 it
handed the judge two findings that were comments inside this plugin's own
scripts, from a run where the model reported nothing at all.

The JSON events keep the two apart: `text` events are what the model said,
`tool_use` events are what it did. So the report is exactly that, in order:

    ## <model> - 14 calls, 2m14s
      read  scripts/probe.sh
      bash  git diff main...HEAD          [failed]
      ... 170 more calls, all of them in <calls file>

    ## Answer
    <what the model actually wrote>

The call list is the point of the exercise as much as the answer is: a
finding about a file the reviewer never opened is a finding it invented, and
that is only visible if what it opened is written down.

Exit codes: 0 = report written; 2 = the input held no JSON events at all (an
opencode too old for --format json); 3 = events, but the model never said
anything. The caller needs the difference: 2 means fall back to the raw
capture, 3 means this reviewer produced nothing and a retry is in order.
"""
import json
import os
import sys

# Above this many calls the list is cut; the caller gets a pointer to the
# full list on disk. Neither number is load-bearing -- long enough to read a
# whole small review, short enough not to bury the answer.
MAX_INLINE_CALLS = 30
KEEP_INLINE = 20

# Where a tool's interesting argument hides, per tool. First match wins.
ARG_KEYS = ("filePath", "command", "pattern", "path", "query", "url", "description")


def shorten(v):
    """Absolute paths inside the repo are noise: the reader knows where they are."""
    here = os.getcwd() + os.sep
    return v[len(here):] if v.startswith(here) else v


def arg_of(inp):
    if not isinstance(inp, dict):
        return ""
    for k in ARG_KEYS:
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            return shorten(v.strip().replace("\n", " "))
    return json.dumps(inp, ensure_ascii=False)


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: opencode-report.py <events.jsonl> [--out FILE] [--calls FILE] [--model NAME]", file=sys.stderr)
        return 2
    src, out_path, calls_path, model = args[0], None, None, ""
    i = 1
    while i < len(args):
        if args[i] == "--out":
            out_path = args[i + 1]; i += 2
        elif args[i] == "--calls":
            calls_path = args[i + 1]; i += 2
        elif args[i] == "--model":
            model = args[i + 1]; i += 2
        else:
            print(f"unknown arg: {args[i]}", file=sys.stderr); return 2

    calls, texts, stamps, seen_json = [], [], [], False
    with open(src, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            seen_json = True
            ts = ev.get("timestamp")
            if isinstance(ts, int):
                stamps.append(ts)
            part = ev.get("part") or {}
            if ev.get("type") == "text":
                t = part.get("text", "")
                if t:
                    texts.append(t)
            elif ev.get("type") == "tool_use":
                state = part.get("state") or {}
                status = state.get("status", "")
                calls.append((part.get("tool", "?"), arg_of(state.get("input")), status))

    if not seen_json:
        # Not JSON at all: this opencode predates --format json. Say so and let
        # the caller keep whatever it captured.
        print("no JSON events in input", file=sys.stderr)
        return 2

    # Failures are worth seeing: a reviewer whose greps all failed read nothing.
    lines = []
    took = ""
    if len(stamps) >= 2:
        secs = max(0, (max(stamps) - min(stamps)) // 1000)
        took = f", {secs // 60}m{secs % 60:02d}s" if secs >= 60 else f", {secs}s"
    lines.append(f"## {model or 'opencode'} — {len(calls)} tool call(s){took}")

    shown = calls if len(calls) <= MAX_INLINE_CALLS else calls[:KEEP_INLINE]
    for tool, arg, status in shown:
        mark = "" if status == "completed" else f"   [{status or 'no status'}]"
        lines.append(f"  {tool:<6} {arg[:150]}{mark}")
    if len(calls) > len(shown):
        rest = len(calls) - len(shown)
        where = calls_path or "(not written: no --calls given)"
        lines.append(f"  … {rest} more call(s), all of them in {where}")
    if not calls:
        # The single most useful line in the whole report.
        lines.append("  (none — this reviewer answered without opening anything)")

    answer = "".join(texts).strip()
    lines.append("")
    lines.append("## Answer")
    lines.append(answer if answer else "(the model produced no answer text at all)")

    report = "\n".join(lines) + "\n"
    if out_path:
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(report)
    else:
        sys.stdout.write(report)

    if calls_path and calls:
        with open(calls_path, "w", encoding="utf-8") as fh:
            for tool, arg, status in calls:
                fh.write(f"{tool}\t{status}\t{arg}\n")
    return 0 if answer else 3


if __name__ == "__main__":
    sys.exit(main())
