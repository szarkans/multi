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
# Finished arms are skipped by case and arm alone, so one output directory holds
# one experiment: refuse to mix a different mode, level or model into it.
settings="mode=$MODE builtin=$BUILTIN_LEVEL multi=$MULTI_MODE model=$MODEL"
if [ -f "$OUT/.settings" ] && [ "$(cat "$OUT/.settings")" != "$settings" ]; then
  echo "$OUT holds a run with: $(cat "$OUT/.settings") -- not mixing in: $settings. Use another --out." >&2; exit 2
fi
printf '%s\n' "$settings" > "$OUT/.settings"

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

# A run killed by the account's usage limit is not a result. On 2026-09-11 the
# 5-hour window ran out mid-night and 40 runs died in seconds, in three shapes:
#   - the whole report is the limit message ("You've hit your session limit");
#   - the whole report is "Failed to authenticate. API Error: 403 ...";
#   - an empty report from a "successful" session that cost $0.
# Judge by the report, never by a "rejected" rate-limit event in the transcript:
# five more runs carried one and still finished a full report, because the
# session had switched to paid overage and kept going. The report shape caught
# all 40 dead runs and none of the 12 live ones.
# A dead attempt is moved aside -- the watcher and the checker must never take
# it for a result while this script waits hours for the window -- and the arm
# is redone once the gate lets it through. Re-running the same command skips
# every arm that already has a real result.
STUB='^(Failed to authenticate|API Error|You.ve hit your .*limit)'
limit_hit() { # <prefix>
  # Markers first: a real review never costs nothing.
  grep -q '^cost_usd=0\(\.0*\)\?$' "$1.meta" 2>/dev/null && return 0
  # A run that worked a while and then hit the wall: the whole report is the one
  # stub line. A real report that merely quotes such a line has more lines.
  [ -s "$1.txt" ] && [ "$(grep -c . "$1.txt")" -le 1 ] && grep -qE "$STUB" "$1.txt"
}
arm_done() { # <id> <arm>
  local p="$OUT/$1.$2"
  { [ -f "$p.meta" ] && ! limit_hit "$p"; } || return 1
  grep -q '^is_error=True' "$p.meta" && return 1        # an errored run is not a review
  [ -s "$p.txt" ] && return 0
  # No report counts as an outcome only when the timeout killed it: redoing that
  # burns another 90 minutes on the same wall. A crash with no output does not.
  grep -q '^is_error=killed' "$p.meta" && grep -q '^exit=124$' "$p.err" 2>/dev/null
}
set_aside() { # <id> <arm>
  # A fresh suffix every time: an earlier night's evidence is never overwritten.
  local p="$OUT/$1.$2" f sfx=".limit-$(date +%Y%m%d-%H%M%S)"
  for f in "$p.txt" "$p.meta" "$p.jsonl" "$p.err"; do [ -e "$f" ] && mv "$f" "$f$sfx"; done
  if [ -d "$OUT/runs/$1.$2" ]; then mv "$OUT/runs/$1.$2" "$OUT/runs/$1.$2$sfx"; fi
}
INCOMPLETE=""
arm() { # <id> <arm> <worktree> <command>
  if arm_done "$1" "$2"; then echo "[$1] $2: already done"; return; fi
  local n
  for n in 1 2 3; do
    # The gate returns 0 only when there is room. Any other exit means it was
    # killed, not cleared -- starting anyway is how a night gets burned.
    if ! GATE_LOG="$OUT/usage-gate.log" bash "$HERE/usage-gate.sh"; then
      echo "[$1] $2: usage gate did not clear, skipped"; INCOMPLETE="$INCOMPLETE $1.$2"; return
    fi
    run_arm "$@"
    if ! limit_hit "$OUT/$1.$2"; then
      arm_done "$1" "$2" || INCOMPLETE="$INCOMPLETE $1.$2"
      return
    fi
    echo "[$1] $2: touched the usage limit (attempt $n), set aside"
    set_aside "$1" "$2"
  done
  echo "[$1] $2: usage limit on three attempts in a row, left for the next run"
  INCOMPLETE="$INCOMPLETE $1.$2"
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
    builtin|both) arm "$id" builtin "$wt" "/code-review $BUILTIN_LEVEL $target" ;;
  esac
  case "$ARM" in
    # Headless has no background-task notifications: the judge must block on
    # wait.sh itself and finish the report in this one turn, as it would after
    # the notification in an interactive session.
    multi|both) arm "$id" multi "$wt" "/multi:code-review $MULTI_MODE $target
(This is a headless run. There are no background-task notifications here. Do not end your turn before the final report: run wait.sh in the foreground and call it again whenever it exits 1, then judge and write the full report.)" ;;
  esac
done 3< "$CASES"
# An unattended night must not end in a clean exit with holes in it.
if [ -n "$INCOMPLETE" ]; then
  echo "arms done -> $OUT -- still without a result (re-run the same command):$INCOMPLETE"; exit 1
fi
echo "arms done -> $OUT"
