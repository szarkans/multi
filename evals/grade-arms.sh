#!/usr/bin/env bash
# Grade run-arms.sh output blind to the arm.
#
#   grade-arms.sh --out <dir> [--case <id>] [--model sonnet]
#
# Two headless passes per report, neither told which arm produced it:
#   1. flatten  — every distinct finding as `file | line | claim`, headers,
#                 reviewer names, severities and verdict prose stripped, so a
#                 "Corroborated" header cannot give the arm away;
#   2. grade    — flat list vs the case's truth, strict: FOUND only if same
#                 defect, same mechanism, same place. Writes <id>.<arm>.grade
#                 with VERDICT, N_FINDINGS and the quote that earned it.
# Then prints a per-case table with cost and duration from the .meta files.
set -uo pipefail
OUT=""; ONLY=""; MODEL=sonnet
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --case) ONLY="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "usage: grade-arms.sh --out <dir> [--case id]" >&2; exit 2; }

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
  # Cached flatten/votes are only reused when they are newer than the report.
  for f in "$base.flat.txt" "$base.grade1" "$base.grade2" "$base.grade3"; do
    [ -f "$f" ] && [ ! "$f" -nt "$report" ] && rm -f "$f"
  done
  [ -s "$base.flat.txt" ] || {
    { printf 'Below is a code-review report. Extract EVERY distinct finding it makes as one line each (one line per underlying problem: a finding that cites several line ranges or is repeated under several headings is ONE line), format exactly:\nFILE:LINE | one-sentence claim of the defect\nDrop headers, section names, reviewer names, severities, confidence, verdicts and recommendations. If a finding has no line, write FILE:? . If the report says the code is clean, output the single line NONE. Output only the lines.\n\n=== REPORT ===\n'; cat "$report"; } \
      | claude -p --setting-sources "" --model "$MODEL" --output-format text > "$base.flat.txt" 2>/dev/null
  }
  if [ ! -s "$base.flat.txt" ]; then
    printf 'VERDICT: UNGRADED\nVOTES: -\nN_FINDINGS: ?\nQUOTE: (flatten call returned nothing)\n' > "$base.grade"; continue
  fi
  # Three independent votes: the same flat list has come back FOUND and PARTIAL
  # from one grader. Majority wins; a split is printed for a human to settle.
  for v in 1 2 3; do
    [ -s "$base.grade$v" ] && continue
    { printf 'You grade a code review against a known real bug. Strict rubric:\nFOUND = a finding names the same defect with the same failure mechanism at the same place (file/function). Wording, variable names and the exact trigger phrasing may differ; what matters is that a reader of the finding would fix this bug.\nPARTIAL = right place and right class of problem, but the mechanism or consequence is different or vague.\nMISS = nothing matches; thematic near-misses are MISS.\nAnswer exactly three lines:\nVERDICT: FOUND|PARTIAL|MISS\nN_FINDINGS: <number of finding lines in the list, 0 if NONE>\nQUOTE: <the single finding line that earned the verdict, or "-">\n\n=== TRUE BUG ===\n'; cat "$OUT/$id.truth.txt"; printf '\n=== FINDINGS ===\n'; cat "$base.flat.txt"; } \
      | claude -p --setting-sources "" --model "$MODEL" --output-format text > "$base.grade$v" 2>/dev/null
  done
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
