#!/usr/bin/env bash
# Control-arm harness for issue #25: is /multi:code-review better than the
# built-in /code-review, and what does it cost?
#
#   run-arms.sh --cases <file> --out <dir> [--case <id>] [--mode intro|blind]
#               [--arm builtin|multi|both] [--builtin-level high]
#               [--multi-mode normal] [--model sonnet]
#
# Same worktree, same target, one headless `claude -p` per arm. The worktree is
# prepared by run.sh --prep-only (intro: checkout at the bug-introducing commit,
# target HEAD~1..HEAD; blind: checkout at fix^, target = the case's paths).
# Per arm and case it leaves:
#   <id>.<arm>.jsonl  the stream-json transcript (survives a kill)
#   <id>.<arm>.txt    the final report — what a human would have read
#   <id>.<arm>.meta   cost_usd, duration_s, turns, is_error
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CASES=""; OUT=""; ONLY=""; MODE=intro; ARM=both
BUILTIN_LEVEL=high; MULTI_MODE=normal; MODEL=sonnet; TIMEOUT="${ARM_TIMEOUT:-2700}"
while [ $# -gt 0 ]; do
  case "$1" in
    --cases) CASES="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --case) ONLY="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --arm) ARM="$2"; shift 2 ;;
    --builtin-level) BUILTIN_LEVEL="$2"; shift 2 ;;
    --multi-mode) MULTI_MODE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$ARM" in builtin|multi|both) ;; *) echo "--arm must be builtin, multi or both" >&2; exit 2 ;; esac
case "$MODE" in intro|blind) ;; *) echo "--mode must be intro or blind" >&2; exit 2 ;; esac
[ -n "$CASES" ] && [ -n "$OUT" ] || { echo "usage: run-arms.sh --cases <file> --out <dir> [--case id] [--mode intro|blind] [--arm builtin|multi|both]" >&2; exit 2; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

run_arm() { # <id> <arm> <worktree> <command>
  local id="$1" arm="$2" wt="$3" cmd="$4" jsonl="$OUT/$1.$2.jsonl"
  echo "[$id] $arm: $cmd"
  # A judge has been seen persisting its run-dir path to fixed /tmp files and a
  # later session picking them up — reviewing another case's run. Clear them.
  rm -f /tmp/review_run_path.txt /tmp/review_repo_path.txt
  local t0=$(date +%s)
  # Each run gets its own run-dir base: run-dir.sh keys on the session id, and
  # two headless sessions have been seen landing in one directory.
  # Headless claude kills a session's background tasks after 600s by default
  # ("Background tasks still running after 600s; terminating") — the built-in
  # review's finder agents and multi's ask.sh both run in the background and
  # a cut run leaves an empty report that grades as a MISS. Wait indefinitely.
  ( cd "$wt" && MULTI_RUN_BASE="$OUT/runs/$id.$arm" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
      timeout "$TIMEOUT" claude -p "$cmd" --model "$MODEL" < /dev/null \
      --output-format stream-json --verbose ) > "$jsonl" 2> "$OUT/$id.$arm.err"
  echo "exit=$?" >> "$OUT/$id.$arm.err"
  echo "wall_s=$(( $(date +%s) - t0 ))" >> "$OUT/$id.$arm.err"
  python3 - "$jsonl" "$OUT/$id.$arm" <<'PY'
import json, sys
src, prefix = sys.argv[1], sys.argv[2]
# A headless session can emit several result events: the report, then short
# "background task woke me, nothing new" turns. The report is the longest
# text; cost and usage are cumulative, so they come from the LAST event.
res = None; last = None
for line in open(src, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: ev = json.loads(line)
    except ValueError: continue
    if ev.get("type") != "result": continue
    last = ev
    if len(ev.get("result") or "") >= len((res or {}).get("result") or ""): res = ev
if res is None:
    open(prefix + ".txt", "w").write("")
    open(prefix + ".meta", "w").write("cost_usd=\nduration_s=\nturns=\nis_error=killed\n")
    sys.exit(0)
open(prefix + ".txt", "w", encoding="utf-8").write(res.get("result") or "")
u = last.get("usage") or {}
open(prefix + ".meta", "w").write(
    "cost_usd=%s\nduration_s=%s\nturns=%s\nis_error=%s\ninput=%s\noutput=%s\ncache_read=%s\ncache_create=%s\n" % (
    last.get("total_cost_usd"), round((res.get("duration_ms") or 0)/1000), res.get("num_turns"),
    last.get("is_error") or res.get("is_error"), u.get("input_tokens"), u.get("output_tokens"),
    u.get("cache_read_input_tokens"), u.get("cache_creation_input_tokens")))
PY
  grep '^wall_s=' "$OUT/$id.$arm.err" >> "$OUT/$id.$arm.meta"
  echo "[$id] $arm done: $(tr '\n' ' ' < "$OUT/$id.$arm.meta")"
}

while IFS=$'\t' read -r -u 3 id case_repo sha paths truth intro_sha severity _rest; do
  case "$id" in ''|\#*) continue ;; esac
  [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue
  wt="$OUT/worktrees/$id"
  # Prep is idempotent: a worktree already at the right commit is reused, so
  # two arms (or two batches) can share it — run.sh would rm -rf it otherwise.
  want="$intro_sha"; [ "$MODE" != blind ] || want="${sha}^"
  if [ -n "$want" ] && [ -d "$wt" ] && [ -s "$OUT/$id.truth.txt" ] \
     && [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$(git -C "$case_repo" rev-parse "$want" 2>/dev/null)" ]; then
    echo "[$id] worktree reused"
    printf '%s\n' "$truth" > "$OUT/$id.truth.txt"   # the case file may have been edited since
  else
    bash "$HERE/run.sh" --cases "$CASES" --out "$OUT" --case "$id" --mode "$MODE" --prep-only \
      > "$OUT/$id.prep.log" 2>&1 || { echo "[$id] SKIP: prep failed"; cat "$OUT/$id.prep.log"; continue; }
    grep -q 'prepared' "$OUT/$id.prep.log" || { echo "[$id] SKIP: $(cat "$OUT/$id.prep.log")"; continue; }
  fi
  if [ "$MODE" = intro ]; then
    target="HEAD~1..HEAD"
    # Both arms must see the same diff as the harness wrote to <id>.diff.txt.
    n_h=$(wc -l < "$OUT/$id.diff.txt"); n_w=$(git -C "$wt" diff HEAD~1..HEAD | wc -l)
    [ "$n_h" = "$n_w" ] || echo "[$id] WARNING: diff.txt $n_h lines vs worktree HEAD~1..HEAD $n_w lines"
  else
    target="$paths"
  fi
  case "$ARM" in
    builtin|both) run_arm "$id" builtin "$wt" "/code-review $BUILTIN_LEVEL $target" ;;
  esac
  case "$ARM" in
    # Headless has no background-task notifications: the judge must block on
    # wait.sh itself and finish the report in this one turn, as it would after
    # the notification in an interactive session.
    multi|both) run_arm "$id" multi "$wt" "/multi:code-review $MULTI_MODE $target
(This is a headless run. There are no background-task notifications here. Do not end your turn before the final report: run wait.sh in the foreground and call it again whenever it exits 1, then judge and write the full report.)" ;;
  esac
done 3< "$CASES"
echo "arms done -> $OUT"
