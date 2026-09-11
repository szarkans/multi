#!/usr/bin/env bash
# Grade run-arms.sh output blind to the arm.
#
#   grade-arms.sh --out <dir> [--case <id>] [--model sonnet] [--cases <file>]
#
# Two headless passes per report, neither told which arm produced it:
#   1. flatten  — every distinct finding as `file | line | claim`, headers,
#                 reviewer names, severities and verdict prose stripped, so a
#                 "Corroborated" header cannot give the arm away;
#   2. grade    — flat list vs the case's truth, strict: FOUND only if same
#                 defect, same mechanism, same place. Writes <id>.<arm>.grade
#                 with VERDICT, N_FINDINGS and the quote that earned it.
# Then prints a per-case table with cost and duration from the .meta files, and --
# given --cases -- a breakdown by severity, intro-diff size and repo. One overall
# recall number hides which class the pipeline is blind to, which is the only thing
# a larger corpus actually buys.
set -uo pipefail
OUT=""; ONLY=""; MODEL=sonnet; CASES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --case) ONLY="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --cases) CASES="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "usage: grade-arms.sh --out <dir> [--case id]" >&2; exit 2; }

# A call made while the account is over its usage limit answers with the limit
# message, not a finding list or a vote. Nothing that is not shaped like an
# answer is kept, fresh or cached.
flat_ok() { grep -q '|\|^NONE' "$base.flat.txt" 2>/dev/null; }
vote_ok() { grep -q '^VERDICT:' "$base.grade$1" 2>/dev/null; }
ungraded() { printf 'VERDICT: UNGRADED\nVOTES: -\nN_FINDINGS: ?\nQUOTE: (%s)\n' "$1" > "$base.grade"; }
gate() { GATE_LOG="$OUT/usage-gate.log" bash "$(dirname "$0")/usage-gate.sh"; }

for report in "$OUT"/*.builtin.txt "$OUT"/*.multi.txt; do
  [ -f "$report" ] || continue
  base="${report%.txt}"; id="$(basename "$base")"; id="${id%.*}"
  [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue
  [ -s "$OUT/$id.truth.txt" ] || { echo "$id: no truth"; continue; }
  # Anything that is not a finished report grades as such, never as a MISS:
  # a killed/errored run, an empty report, a flatten call that came back empty.
  if grep -q '^is_error=\(True\|killed\)' "$base.meta" 2>/dev/null; then
    printf 'VERDICT: ERROR\nVOTES: -\nN_FINDINGS: 0\nQUOTE: (run errored — see .meta/.err)\n' > "$base.grade"; continue
  fi
  if [ ! -s "$report" ]; then
    printf 'VERDICT: EMPTY\nVOTES: -\nN_FINDINGS: 0\nQUOTE: (empty report)\n' > "$base.grade"; continue
  fi
  # Cached flatten/votes are reused only when newer than the report -- and a
  # vote only when it is newer than the finding list it graded.
  for f in "$base.flat.txt" "$base.grade1" "$base.grade2" "$base.grade3"; do
    [ -f "$f" ] && [ ! "$f" -nt "$report" ] && rm -f "$f"
  done
  # A dropped finding list takes its votes with it: they graded the limit message.
  [ -f "$base.flat.txt" ] && ! flat_ok && rm -f "$base.flat.txt" "$base.grade1" "$base.grade2" "$base.grade3"
  for v in 1 2 3; do
    [ -f "$base.grade$v" ] || continue
    { vote_ok $v && [ "$base.grade$v" -nt "$base.flat.txt" ]; } || rm -f "$base.grade$v"
  done
  if [ ! -s "$base.flat.txt" ]; then
    gate || { ungraded "usage gate did not clear"; continue; }
    { printf 'Below is a code-review report. Extract EVERY distinct finding it makes as one line each (one line per underlying problem: a finding that cites several line ranges or is repeated under several headings is ONE line), format exactly:\nFILE:LINE | one-sentence claim of the defect\nDrop headers, section names, reviewer names, severities, confidence, verdicts and recommendations. If a finding has no line, write FILE:? . If the report says the code is clean, output the single line NONE. Output only the lines.\n\n=== REPORT ===\n'; cat "$report"; } \
      | claude -p --setting-sources "" --model "$MODEL" --output-format text > "$base.flat.txt" 2>/dev/null
    flat_ok || { rm -f "$base.flat.txt"; ungraded "flatten gave no finding list -- re-run to retry"; continue; }
  fi
  # Three independent votes: the same flat list has come back FOUND and PARTIAL
  # from one grader. Majority wins; a split is printed for a human to settle.
  for v in 1 2 3; do
    vote_ok $v && continue
    gate || break
    { printf 'You grade a code review against a known real bug. Strict rubric:\nFOUND = a finding names the same defect with the same failure mechanism at the same place (file/function). Wording, variable names and the exact trigger phrasing may differ; what matters is that a reader of the finding would fix this bug.\nPARTIAL = right place and right class of problem, but the mechanism or consequence is different or vague.\nMISS = nothing matches; thematic near-misses are MISS.\nAnswer exactly three lines:\nVERDICT: FOUND|PARTIAL|MISS\nN_FINDINGS: <number of finding lines in the list, 0 if NONE>\nQUOTE: <the single finding line that earned the verdict, or "-">\n\n=== TRUE BUG ===\n'; cat "$OUT/$id.truth.txt"; printf '\n=== FINDINGS ===\n'; cat "$base.flat.txt"; } \
      | claude -p --setting-sources "" --model "$MODEL" --output-format text > "$base.grade$v" 2>/dev/null
    vote_ok $v || rm -f "$base.grade$v"
  done
  # All three or no verdict: a starved call must not turn one vote into a majority.
  if ! vote_ok 1 || ! vote_ok 2 || ! vote_ok 3; then ungraded "fewer than three votes came back -- re-run to retry"; continue; fi
  votes="$(for v in 1 2 3; do sed -n 's/^VERDICT: *\(FOUND\|PARTIAL\|MISS\).*/\1/p' "$base.grade$v" | head -1; done | sort | uniq -c | sort -rn)"
  top="$(printf '%s\n' "$votes" | head -1 | awk '{print $2}')"; cnt="$(printf '%s\n' "$votes" | head -1 | awk '{print $1}')"
  if [ -z "$top" ] || [ "${cnt:-0}" -lt 2 ]; then
    [ -n "$top" ] && top="SPLIT" || top="UNGRADED"
  fi
  # The quote and count come from a vote that agrees with the majority.
  win=""; for v in 1 2 3; do grep -q "^VERDICT: *$top" "$base.grade$v" 2>/dev/null && { win="$base.grade$v"; break; }; done
  [ -n "$win" ] || win="$base.grade1"
  { printf 'VERDICT: %s\nVOTES: %s\n' "$top" "$(printf '%s' "$votes" | tr '\n' ';')"; sed -n 's/^N_FINDINGS:.*/&/p' "$win" | head -1; sed -n 's/^QUOTE:.*/&/p' "$win" | head -1; } > "$base.grade"
done

echo
printf '%-36s %-8s %-8s %5s %9s %6s\n' case arm verdict n cost_usd dur_s
for grade in "$OUT"/*.grade; do
  [ -f "$grade" ] || continue
  base="${grade%.grade}"; arm="${base##*.}"; id="$(basename "${base%.*}")"
  [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue
  v="$(sed -n 's/^VERDICT: *//p' "$grade" | head -1)"; n="$(sed -n 's/^N_FINDINGS: *//p' "$grade" | head -1)"
  c="$(sed -n 's/^cost_usd=//p' "$base.meta" 2>/dev/null)"; d="$(sed -n 's/^wall_s=//p' "$base.meta" 2>/dev/null)"
  printf '%-36s %-8s %-8s %5s %9.2f %6s\n' "$id" "$arm" "${v:-?}" "${n:-?}" "${c:-0}" "${d:-?}"
done

[ -n "$CASES" ] || exit 0
python3 - "$OUT" "$CASES" "$ONLY" <<'BREAKDOWN'
import os, sys, re
from collections import defaultdict
out, cases, only = sys.argv[1], sys.argv[2], sys.argv[3]

meta = {}
for line in open(cases, encoding="utf-8"):
    if line.startswith("#") or "\t" not in line: continue
    f = line.rstrip("\n").split("\t")
    if len(f) < 7: continue
    n = int(f[7]) if len(f) > 7 and f[7].strip().isdigit() else None
    size = "?" if n is None else ("S <300" if n < 300 else ("M 300-599" if n < 600 else "L 600+"))
    meta[f[0]] = dict(sev=f[6] or "?", size=size, repo=f[1].rstrip("/").split("/")[-1])

tally = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(int))))
missing = []
for name in sorted(os.listdir(out)):
    if not name.endswith(".grade"): continue
    cid, _, arm = name[:-len(".grade")].rpartition(".")
    if only and only != cid: continue
    if cid not in meta:
        missing.append(cid); continue
    v = ""
    for line in open(os.path.join(out, name), encoding="utf-8"):
        m = re.match(r"VERDICT: *(\S+)", line)
        if m: v = m.group(1); break
    m = meta[cid]
    for axis, bucket in (("severity", m["sev"]), ("diff size", m["size"]), ("repo", m["repo"])):
        tally[axis][bucket][arm][v or "?"] += 1

if missing:
    print("\nnot in --cases, left out of the breakdown: " + " ".join(sorted(set(missing))))
for axis in ("severity", "diff size", "repo"):
    if not tally[axis]: continue
    print("\nby %s" % axis)
    # Only graded reports count toward recall: a run that errored or a grade that
    # never came back says nothing about the reviewer, and is shown apart.
    print("  %-26s %-8s %5s %5s %5s %5s %6s %7s" % (axis, "arm", "found", "part", "miss", "n", "failed", "recall"))
    for bucket in sorted(tally[axis]):
        for arm in sorted(tally[axis][bucket]):
            c = tally[axis][bucket][arm]
            f, pa, mi = c.get("FOUND", 0), c.get("PARTIAL", 0), c.get("MISS", 0)
            n = f + pa + mi
            print("  %-26s %-8s %5d %5d %5d %5d %6d %6.0f%%" % (
                bucket, arm, f, pa, mi, n, sum(c.values()) - n, 100.0 * f / n if n else 0))
BREAKDOWN
