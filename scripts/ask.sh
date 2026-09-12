#!/usr/bin/env bash
# Put one question to Codex and OpenCode at the same time and write each answer
# to its own file. No review prompt, no parsing, no judging — whatever the
# question is, the answers come back raw.
#
#   ask.sh --question "is a channel or a mutex better here?" --out-prefix "$RUN/ask"
#   ask.sh --question-file "$RUN/prompt.md" --out-prefix "$RUN/done" --effort high
#   ask.sh --question-file "$RUN/review.md" --out-prefix "$RUN/review" --timeout 2400
#   ask.sh --question "..." --out-prefix /tmp/f2 --backend codex
#   ask.sh --question "..." --out-prefix /tmp/f4 --backend openrouter:x-ai/grok-4.5
#   ask.sh --question "..." --out-prefix /tmp/all --backend all
#   ask.sh --question "..." --out-prefix /tmp/two --backend "openrouter:z-ai/glm-5.2:free,openrouter:x-ai/grok-4.5"
#
# --backend picks who answers. Backends and profiles live in
# $MULTI_HOME/config.toml (scripts/config.py reads it; no file = the built-in
# default: codex, opencode, openrouter). The value is a profile name from that
# file, `all` (every configured backend), `both` (codex + opencode), or a
# comma-separated list of entries. An entry is a backend name — its whole
# configured model chain, walked in order — or name:model, which runs exactly
# that model with no fallback. Split on the FIRST colon only, because model
# names can contain colons themselves (z-ai/glm-5.2:free). The same backend
# can appear more than once with a different model — comparing two OpenRouter
# models does not need two runs. No --backend at all runs default_profile.
# A backend inside one of its `avoid` windows (config.toml) is not launched;
# its answer file says so and when it is back. --ignore-avoid runs every
# backend as if it had no windows, this run only: the user's "I don't care
# about peak hours, run it" -- the config is not touched.
# One backend at a time is what lets a caller send a DIFFERENT question to
# each model in parallel instead of the same one to all.
#
# --model/--fallback (opencode) and --codex-model set the model for a bare
# (no-colon) entry of that type for this run only, over the config's chain.
# --fallback is a comma-separated model list for opencode, tried in order.
# Anything else is pinned as name:model. --timeout N raises every backend to
# at least N for this run; a backend configured higher keeps its own.
#
# openrouter runs Claude Code itself against OpenRouter's Anthropic endpoint —
# same agent loop, different weights. gemini runs the Google CLI, because
# Google has no Anthropic-compatible endpoint and its own CLI keeps the free
# daily quota. Both need a key: see scripts/providers.sh and scripts/setup.sh.
#
# Writes:
#   <prefix>-<backend>.txt              one file per backend instance, or a
#                                        line saying why it did not run
#   <prefix>-<backend>-2.txt, -3.txt...  second and later instance of the same
#                                        backend (e.g. two openrouter entries)
#   <prefix>-<backend>.txt.running      while that backend runs: "<pid of its
#                                        runner> <start epoch> <timeout s>", so
#                                        an `ls` says how long it has been going
#   <prefix>-<backend>.txt.dead         one line saying why it failed
#   <prefix>.run                        the roster: one "<backend>" line per
#                                        participant at launch, then a
#                                        "<backend> <seconds>" line as each ends
# scripts/wait.sh --prefix <prefix> blocks on the .running files and prints
# one status line per backend. A prefix whose roster still has a live
# .running is refused: starting over it deletes the running one's answer.
#
# Both READ the repository to answer; neither is meant to change it. But
# "read-only" here is two different, unequal mechanisms, and one has a hole worth
# stating plainly rather than pretending away.
#
# Codex is sandboxed at the OS level (-s read-only): it may run shell commands,
# but writes and network are blocked. Solid.
#
# OpenCode has no OS-level sandbox. Give it a plugin-owned, deny-by-default agent
# instead: project config is disabled, write/edit/apply_patch stay denied, and
# only repository reads plus a small read-only shell allowlist run without a
# prompt. --pure still matters because it disables external plugins; it does not
# disable configuration. Never add --auto here: it approves every permission
# which was not explicitly denied.
set -uo pipefail

# Keys, the child-process isolation and the non-CLI backends all live here.
SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=providers.sh
. "$SELF_DIR/providers.sh"

QUESTION=""; QFILE=""; PREFIX=""; EFFORT=medium; MODEL=""; FALLBACK=""; CODEX_MODEL=""; BACKEND=""; REPO=""; TIMEOUT=""; IGNORE_AVOID=""
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
DETACH_ARGS=()
for a in "$@"; do [ "$a" = "--detach" ] || DETACH_ARGS+=("$a"); done
while [ $# -gt 0 ]; do
  case "$1" in
    --question)      need $# "$1"; QUESTION="$2"; shift 2 ;;
    --question-file) need $# "$1"; QFILE="$2"; shift 2 ;;
    --out-prefix)    need $# "$1"; PREFIX="$2"; shift 2 ;;
    --effort)        need $# "$1"; EFFORT="$2"; shift 2 ;;
    --model)         need $# "$1"; MODEL="$2"; shift 2 ;;
    --fallback)      need $# "$1"; FALLBACK="$2"; shift 2 ;;
    --timeout)       need $# "$1"
                     case "$2" in ''|*[!0-9]*|0) echo "--timeout must be a positive integer: $2" >&2; exit 2 ;; esac
                     TIMEOUT="$2"; shift 2 ;;
    --codex-model)   need $# "$1"; CODEX_MODEL="$2"; shift 2 ;;
    --backend)       need $# "$1"; BACKEND="$2"; shift 2 ;;
    # "Run it anyway": every backend runs as if it had no `avoid` windows, this
    # run only. The config stays as it is -- the alternative was commenting the
    # line out and never putting it back.
    --ignore-avoid)  IGNORE_AVOID=1; shift ;;
    # Where the CLI reviewers run git and read files: the review target, not the
    # process cwd. Default cwd, so /ask and /adhd (no repo) are unaffected.
    --repo)          need $# "$1"; REPO="$2"; shift 2 ;;
    # Run in a session of its own and return at once, printing the pid. For
    # hosts whose shell tool kills its whole process group at a timeout
    # (OpenCode: two minutes by default) -- `nohup … &` dies with the group.
    # python does the setsid: stock macOS ships no `setsid` binary, and python3
    # is already required here (config.toml). stdout/stderr stay as the caller
    # redirected them; stdin is closed.
    --detach)        DETACH=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [ "${DETACH:-0}" = "1" ]; then
  py="$(multi_python)" || { echo "ask.sh --detach: no working python3" >&2; exit 2; }
  "$py" -c 'import os, sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])' "$0" "${DETACH_ARGS[@]}" < /dev/null &
  echo "ask.sh detached, pid $!"
  exit 0
fi
REPO_DIR="${REPO:-.}"
[ -d "$REPO_DIR" ] || { echo "--repo is not a directory: $REPO_DIR" >&2; exit 2; }
[ -n "$PREFIX" ] || { echo "--out-prefix is required" >&2; exit 2; }
# Make the output prefix absolute BEFORE any backend cd's into --repo: the codex
# path runs inside "$REPO_DIR", and a relative -o/-log would then land in the
# reviewed tree while the parent checks it back here and sees "no output".
case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac
# The caller hands us a per-run directory (scripts/run-dir.sh); create it here
# so every entry point gets it, not just the ones that remember.
mkdir -p "$(dirname "$PREFIX")" 2>/dev/null || true
if [ -n "$QFILE" ]; then
  [ -z "$QUESTION" ] || { echo "pass --question or --question-file, not both" >&2; exit 2; }
  [ -s "$QFILE" ] || { echo "--question-file is empty or missing: $QFILE" >&2; exit 2; }
  QUESTION="$(cat "$QFILE")"
fi
[ -n "$QUESTION" ] || { echo "--question or --question-file is required" >&2; exit 2; }

# Who runs, from the config: one tab-separated line per participant, a typo
# or a broken config stops everything here, before anything is launched.
# Empty fields come as "-" so a whitespace IFS cannot collapse them.
RESOLVED="$(multi_config resolve ${BACKEND:+--backend "$BACKEND"} ${TIMEOUT:+--timeout "$TIMEOUT"} ${IGNORE_AVOID:+--ignore-avoid})" || exit 2
# Parallel arrays rather than one associative one: bash 3.2 -- the /bin/bash
# every stock macOS ships -- has no `declare -A`, and it fails there at run
# time, mid-script, with exit 0: ask.sh printed "declare: -A: invalid option"
# and the caller saw success.
NAMES=(); MODELS=(); SUFFIXES=(); TYPES=(); CHAINS=(); URLS=(); KEYENVS=(); TIMEOUTS=(); STALLS=(); CLOSED=()
dash() { [ "$1" = "-" ] && printf '' || printf '%s' "$1"; }
while IFS="$(printf '\t')" read -r suffix name type pinned chain url keyenv timeout stall closed; do
  [ -n "$suffix" ] || continue
  # Ten columns; a shape change in config.py must fail here, not misroute.
  # The LAST variable of `read` takes the rest of the line, so the check is on
  # it: a column added after it without a name here would ride into the
  # previous one as "text<tab>text".
  [ -n "$closed" ] || { echo "config.py resolve: unexpected line shape: $suffix ..." >&2; exit 2; }
  SUFFIXES+=("$suffix"); NAMES+=("$name"); TYPES+=("$type"); MODELS+=("$(dash "$pinned")")
  CHAINS+=("$(dash "$chain")"); URLS+=("$(dash "$url")"); KEYENVS+=("$keyenv"); TIMEOUTS+=("$timeout"); STALLS+=("$stall")
  CLOSED+=("$(dash "$closed")")
done <<EOF
$RESOLVED
EOF
[ "${#NAMES[@]}" -gt 0 ] || { echo "--backend: nothing to run" >&2; exit 2; }

# 0 = there is an answer, 3 = the model said nothing, 2 = the capture is not
# JSON (an opencode older than --format json), 4 = no python3 to read it with.
render_opencode() { # render_opencode <raw> <out> <model>
  local py; py="$(multi_python)" || return 4
  rm -f "${2}.calls" "${2}.error"
  "$py" "$SELF_DIR/opencode-report.py" "$1" --out "$2" --calls "${2}.calls" --model "$3" 2>"${2}.error"
}

run_codex_one() {
  local out="$1" model="$2" rc=0 timeout="$MULTI_BACKEND_TIMEOUT"
  # A stale marker from a previous run with the same prefix must not condemn
  # this run: the sidecar describes one invocation, not the file forever.
  rm -f "${out}.dead"
  command -v codex >/dev/null 2>&1 || { multi_fail_backend "$out" "codex: MISSING"; return 0; }
  # A hung CLI used to block the `wait` below forever, and the caller — usually
  # Claude Code's own bash tool — killed the whole script instead, so every
  # other backend's answer died with it.
  # cwd is $REPO_DIR — the dispatch loop cd's every backend into the target.
  # -c project_doc_max_bytes=0: codex otherwise absorbs the reviewed tree's
  # AGENTS.md as trusted instructions; tree rules are untrusted data, and legit
  # context arrives via collect-context instead.
  # --skip-git-repo-check: a review target is now an isolated snapshot copy
  # (scripts/snapshot.sh) with no .git, and codex otherwise refuses to start
  # outside a git repo ("Not inside a trusted directory"). It reads the files and
  # the copy's review.diff; it needs no git history. Harmless when the target IS
  # a repo (/ask, /adhd), so it is unconditional.
  multi_timeout "$timeout" codex exec \
    ${model:+-m "$model"} \
    -s read-only \
    --skip-git-repo-check \
    -c model_reasoning_effort="$EFFORT" \
    -c project_doc_max_bytes=0 \
    -o "$out" \
    "$QUESTION" >/dev/null 2>"${out}.log"
  rc=$?
  # stderr used to go to /dev/null, so a codex that failed left "NO OUTPUT" and
  # nothing to go on. The openrouter path keeps a .log for exactly this reason.
  if [ "$rc" -eq 124 ] && [ ! -s "$out" ]; then
    multi_fail_backend "$out" "codex: TIMEOUT after ${timeout}s" "${out}.log"
  fi
  [ -s "$out" ] || [ ! -s "${out}.log" ] || multi_fail_backend "$out" "codex: NO OUTPUT — exit=$rc (stderr in ${out}.log)" "${out}.log"
}

run_opencode_one() {
  local out="$1" model="$2" fallback="$3"
  local raw="${out}.jsonl"
  rm -f "${out}.dead" "${raw}.first" "${out}.partial" "${out}.partial.calls"
  command -v opencode >/dev/null 2>&1 || { multi_fail_backend "$out" "opencode: MISSING"; return 0; }
  [ -n "$model" ] || { multi_fail_backend "$out" "opencode: NO MODEL — none of [$MULTI_OPENCODE_CANDIDATES] is in \`opencode models\`; list models under this backend's table in config.toml, or pass --model"; return 0; }
  # --format json rather than the terminal transcript: the transcript mixes the
  # model's answer with every file it opened, and the reader downstream cannot
  # tell those apart. The JSON events can. opencode-report.py turns them into
  # what it did, then what it said.
  local used="$model" rc=0 rrc=0 answered=0 attempted_count=0 silent_count=0 timeout_count=0
  local candidate chain="$model" fallback_models="" attempted="" retry_note="" last_error="" failure_error=""
  local primary_failure="" partial_model="" partial_size=0 best_partial_size=0
  local candidate_pid elapsed stalled effective_stall=0
  if [ "$MULTI_OPENCODE_STALL" -lt "$MULTI_BACKEND_TIMEOUT" ]; then
    effective_stall="$MULTI_OPENCODE_STALL"
  fi
  if [ -n "$fallback" ]; then
    fallback_models="$(printf '%s' "$fallback" | tr ',' ' ')"
    [ -z "$fallback_models" ] || chain="$chain $fallback_models"
  fi
  # No answer or a timeout means the run did not happen cleanly: exhausted
  # usage, an expired subscription, a silent model, or a model that hangs.
  # Neither CLI can be asked about remaining quota beforehand, so walk the
  # free fallback chain here until one model returns a real answer.
  for candidate in $chain; do
    case ",$attempted," in *",$candidate,"*) continue ;; esac
    [ -z "$retry_note" ] || echo "$retry_note — retrying on $candidate" >&2
    used="$candidate"
    attempted="${attempted}${attempted:+,}${used}"
    attempted_count=$((attempted_count+1))
    stalled=0
    elapsed=0
    : > "$raw"
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
      OPENCODE_CONFIG_CONTENT="$(cat "$SELF_DIR/opencode-readonly.json")" \
      GIT_OPTIONAL_LOCKS=0 \
      multi_timeout "$MULTI_BACKEND_TIMEOUT" opencode run --pure --agent multi-readonly --format json \
      -m "$used" --dir "$REPO_DIR" "$QUESTION" > "$raw" 2>&1 &
    candidate_pid=$!
    while kill -0 "$candidate_pid" 2>/dev/null; do
      grep -q '^{' "$raw" 2>/dev/null && break
      if [ "$effective_stall" -gt 0 ] && [ "$elapsed" -ge "$effective_stall" ]; then
        stalled=1
        silent_count=$((silent_count+1))
        multi_kill_tree "$candidate_pid"
        break
      fi
      sleep 1
      elapsed=$((elapsed+1))
    done
    wait "$candidate_pid" 2>/dev/null; rc=$?
    [ "$stalled" -eq 1 ] || [ "$rc" -ne 124 ] || timeout_count=$((timeout_count+1))
    render_opencode "$raw" "$out" "$used"; rrc=$?
    last_error=""
    [ ! -s "${out}.error" ] || last_error="$(sed -n '1p' "${out}.error")"
    [ -z "$last_error" ] || failure_error="$last_error"
    if [ "$stalled" -eq 0 ] && [ "$rc" -ne 124 ] && [ "$rrc" -ne 3 ]; then
      answered=1
      break
    fi
    if [ "$attempted_count" -eq 1 ]; then
      if [ "$stalled" -eq 1 ]; then
        primary_failure="emitted nothing for ${effective_stall}s"
      elif [ "$rc" -eq 124 ]; then
        primary_failure="timed out after ${MULTI_BACKEND_TIMEOUT}s"
      else
        primary_failure="produced no answer"
      fi
    fi
    if [ "$rc" -eq 124 ] && [ "$rrc" -eq 0 ] && [ -s "$out" ]; then
      partial_size="$(wc -c < "$out")"
      if [ "$partial_size" -gt "$best_partial_size" ]; then
        cp "$out" "${out}.partial"
        rm -f "${out}.partial.calls"
        [ ! -e "${out}.calls" ] || cp "${out}.calls" "${out}.partial.calls"
        partial_model="$used"
        best_partial_size="$partial_size"
      fi
    fi
    [ -e "${raw}.first" ] || cp "$raw" "${raw}.first" 2>/dev/null
    if [ "$stalled" -eq 1 ]; then
      retry_note="[multi] $used emitted nothing for ${effective_stall}s — presumed out of quota or never started"
    elif [ "$rc" -eq 124 ]; then
      retry_note="[multi] $used timed out after ${MULTI_BACKEND_TIMEOUT}s"
    else
      retry_note="[multi] $used produced no answer (exit $rc)"
    fi
  done

  if [ "$answered" -eq 0 ] && [ "$best_partial_size" -gt 0 ]; then
    used="$partial_model"
    cp "${out}.partial" "$out"
    rm -f "${out}.calls"
    [ ! -e "${out}.partial.calls" ] || cp "${out}.partial.calls" "${out}.calls"
    { echo "opencode: TIMEOUT after ${MULTI_BACKEND_TIMEOUT}s — model=$used (partial; run was cut off)"
      cat "$out"
    } > "${out}.tmp" && mv "${out}.tmp" "$out"
  elif [ "$answered" -eq 0 ] && [ "$attempted_count" -gt 1 ]; then
    local calls_note=""
    [ ! -e "${out}.calls" ] || calls_note="; what it did is in ${out}.calls"
    if [ "$silent_count" -eq "$attempted_count" ]; then
      multi_fail_backend "$out" "opencode: FALLBACK CHAIN EXHAUSTED — tried $attempted; every model was SILENT/stalled after ${effective_stall}s with no events${calls_note}" "$raw"
    elif [ "$silent_count" -gt 0 ]; then
      if [ "$timeout_count" -gt 0 ]; then
        multi_fail_backend "$out" "opencode: FALLBACK CHAIN EXHAUSTED — tried $attempted; every model ended in TIMEOUT, NO ANSWER, or SILENT/stalled ($silent_count wrote no events for ${effective_stall}s; last exit=$rc${failure_error:+; one model reported: $failure_error})${calls_note}" "$raw"
      else
        multi_fail_backend "$out" "opencode: FALLBACK CHAIN EXHAUSTED — tried $attempted; every model ended in NO ANSWER or SILENT/stalled ($silent_count wrote no events for ${effective_stall}s; last exit=$rc${failure_error:+; one model reported: $failure_error})${calls_note}" "$raw"
      fi
    else
      multi_fail_backend "$out" "opencode: FALLBACK CHAIN EXHAUSTED — tried $attempted; every model ended in TIMEOUT or NO ANSWER (last exit=$rc${failure_error:+; one model reported: $failure_error})${calls_note}" "$raw"
    fi
  elif [ "$stalled" -eq 1 ]; then
    multi_fail_backend "$out" "opencode: SILENT — model=$used wrote no events for ${effective_stall}s (out of quota, or the CLI never started)" "$raw"
  elif [ "$rc" -eq 124 ]; then
    if [ "$rrc" = 0 ] && [ -s "$out" ]; then
      { echo "opencode: TIMEOUT after ${MULTI_BACKEND_TIMEOUT}s — model=$used (partial; run was cut off)"
        cat "$out"
      } > "${out}.tmp" && mv "${out}.tmp" "$out"
    else
      multi_fail_backend "$out" "opencode: TIMEOUT after ${MULTI_BACKEND_TIMEOUT}s — model=$used (partial capture in $raw)" "$raw"
    fi
  elif [ "$rrc" = 3 ]; then
    if [ -n "$last_error" ]; then
      multi_fail_backend "$out" "opencode: NO ANSWER — model=$used exit=$rc — $last_error; what it did is in ${out}.calls" "$raw"
    else
      multi_fail_backend "$out" "opencode: NO ANSWER — model=$used exit=$rc — it ran but said nothing; what it did is in ${out}.calls" "$raw"
    fi
  elif [ "$rrc" = 2 ] && [ "$rc" -ne 0 ]; then
    multi_fail_backend "$out" "opencode: NO OUTPUT — model=$used exit=$rc" "$raw"
  elif [ "$rrc" = 2 ] || [ "$rrc" = 4 ]; then
    local why="an opencode without --format json"; [ "$rrc" = 4 ] && why="no python3 on this machine"
    # Not a dead backend: the model answered, the answer is just unstructured
    # text the caller must read raw. No marker — one here would read a real
    # answer as "no backend alive".
    { echo "opencode: RAW CAPTURE ONLY — model=$used exit=$rc ($why)"
      tail -n 80 "$raw" 2>/dev/null | sed "s/$(printf '\033')\[[0-9;]*[a-zA-Z]//g" | sed 's/^/raw| /'
    } > "$out"
  elif [ ! -s "$out" ]; then
    multi_fail_backend "$out" "opencode: NO OUTPUT — model=$used exit=$rc" "$raw"
  fi
  # A silent model swap is exactly the failure the user fears: the report header
  # now carries the fallback's name, but nothing says the model they ASKED for
  # died. Announce it loud, at the TOP where the reader lands — not a line
  # appended to the very bottom that the eye skates past.
  if [ "$used" != "$model" ] && [ -s "$out" ] && [ ! -e "${out}.dead" ]; then
    { echo "opencode: $model ${primary_failure:-produced no answer} — fell back to $used"; echo
      cat "$out"
    } > "${out}.tmp" && mv "${out}.tmp" "$out"
  fi
  rm -f "${out}.partial" "${out}.partial.calls"
}

# first_of "a b c" -> a ; rest_csv "a b c" -> b,c
first_of() { set -- $1; printf '%s' "${1:-}"; }
rest_csv() { set -- $1; shift 2>/dev/null; printf '%s' "$*" | tr ' ' ','; }

multi_ask_terminated() {
  local signal="$1" pb pid suffix i name f
  trap - TERM INT HUP
  for pb in $pids; do
    pid="${pb%%:*}"
    suffix="${pb#*:}"
    f="${PREFIX}-${suffix}.txt"
    # Ours only: the marker names the runner (or, before started(), this
    # ask.sh). A prefix that a newer run has since taken must not get KILLED
    # written over its answer by a parent that outlived its own children.
    read -r mpid _ 2>/dev/null < "${f}.running" || continue
    [ "$mpid" = "$pid" ] || [ "$mpid" = "$$" ] || continue
    multi_kill_tree "$pid"
    wait "$pid" 2>/dev/null
    name="$suffix"
    for i in "${!SUFFIXES[@]}"; do
      [ "${SUFFIXES[$i]}" = "$suffix" ] && { name="${NAMES[$i]}"; break; }
    done
    # The KILLED marker intentionally overwrites a streaming backend's partial answer.
    multi_fail_backend "$f" "${name}: KILLED — ask.sh was terminated before this backend finished"
    rm -f "${f}.running"
  done
  exit $((128+signal))
}

# Refuse to start over a run that is still going. The loop below rm -f's every
# answer file before launching, and a claude/codex that is still writing to the
# old inode finishes into a deleted file: its runner then finds an empty path
# and marks it NO OUTPUT with exit 0, while the transcript holds a full answer.
# Measured 2026-09-07: four reviews in one session, all on $RUN/review, and
# three sets of glm/openrouter answers went that way. The previous run's
# roster ($PREFIX.run) says which markers to look at -- every one of them, not
# only the backends this run happens to share with it. The pid in a marker is
# the backend's own runner, which outlives a SIGKILLed ask.sh; a pid that is
# gone means a leftover from a killed run -- not a reason to wait.
ROSTER="${PREFIX}.run"
# The check below and the marker writes after it are not one step; two ask.sh
# started within the same second (two sub-agents on one $RUN) would both pass
# and both launch. mkdir is atomic: whoever gets the directory does the check
# and the writes, the other waits. Held for milliseconds, so a lock older than
# a minute belongs to a crash, not a run. NOT mkdir: the uutils (Rust) coreutils
# that Ubuntu 25.10+ ships answer 0 to BOTH of two racing mkdirs -- measured
# 2026-09-07, 17 of 30 races on tmpfs, 30 of 30 on ext4; only the sequential
# case fails. bash's own noclobber open is O_EXCL and needs no binary.
LOCK="${PREFIX}.lock"; n=0
until ( set -o noclobber; echo "$$" > "$LOCK" ) 2>/dev/null; do
  # The holder's pid is in the file; a holder that is gone (SIGKILLed inside
  # these few milliseconds) must not cost every later run a minute and a
  # hand-deleted file. Take over.
  read -r lpid < "$LOCK" 2>/dev/null || lpid=""
  case "$lpid" in ''|*[!0-9]*) ;; *) kill -0 "$lpid" 2>/dev/null || rm -f "$LOCK" ;; esac
  n=$((n+1))
  [ "$n" -lt 60 ] || { echo "ask.sh: $LOCK held for a minute by pid ${lpid:-?} — remove it and retry" >&2; exit 2; }
  sleep 1
done
trap 'rm -f "$LOCK"' EXIT
# After the lock, not before: a wait for it would otherwise be counted into
# every backend's start and duration.
now="$(date +%s)"
{ [ -s "$ROSTER" ] && cut -d' ' -f1 "$ROSTER"; printf '%s\n' "${SUFFIXES[@]}"; } | sort -u | while read -r sfx; do
  r="${PREFIX}-${sfx}.txt.running"
  [ -s "$r" ] || continue
  read -r rpid rstart rtimeout < "$r" || continue
  case "$rpid" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$rpid" 2>/dev/null || continue
  case "$rstart" in ''|*[!0-9]*) rstart="$now" ;; esac
  echo "ask.sh: a run with this prefix is still going: $sfx (pid $rpid, started $((now-rstart))s ago, timeout ${rtimeout:-?}s). Starting now would delete its answer. Wait for it: scripts/wait.sh --prefix \"$PREFIX\" -- or pass another --out-prefix." >&2
  exit 2
done || exit 2

# The roster, then every marker, THEN the launches: a reader that arrives
# mid-launch must see the whole run, not the backends started so far -- a
# fast first backend used to finish and drop its marker before the next one
# was even created, and wait.sh returned "all done" on a half-launched run.
# A reused prefix (loop mode re-reviews with the same $RUN/review) must not
# let last round's answer stand in for a backend that dies before writing --
# a stale non-empty file with no .dead marker reads as a live result.
# The sidecars go too: .dead.log is only ever cleared inside
# multi_fail_backend, so a round that FAILS then SUCCEEDS leaves last round's
# stderr tail sitting next to a live answer -- the same stale-file confusion
# this line exists to close, one filename over.
# Written whole, then renamed: `>` truncates first, and a guard reading the
# marker in between sees an empty file -- "nobody here" -- and launches over a
# live run. Measured: two ask.sh started in the same second, once in twenty.
mark() { # mark <running-file> <pid> <start> <timeout>
  local t="${1}.tmp.$RANDOM$RANDOM"
  printf '%s %s %s\n' "$2" "$3" "$4" > "$t" && mv -f "$t" "$1"
}
# Each backend's subshell, first thing: put ITS pid in the marker. It is the
# process that outlives a SIGKILLed ask.sh and keeps writing the answer, so it
# is the one liveness has to mean. bash 3.2 has no $BASHPID; the parent of a
# fresh sh is this subshell.
# Only if the marker still says the parent: a SIGKILL that hit ask.sh between
# the fork and this line left a marker with a dead pid, another ask.sh may have
# taken the prefix since, and this orphan must then stand down rather than
# write over the new run. $$ in a subshell is still the parent's pid.
started() { # started <out> -> 0 to go on, 1 to stand down
  local cur
  read -r cur _ 2>/dev/null < "${1}.running" && [ "$cur" = "$$" ] || return 1
  mark "${1}.running" "$(sh -c 'echo $PPID')" "$(date +%s)" "$MULTI_BACKEND_TIMEOUT"
}
for i in "${!NAMES[@]}"; do
  out="${PREFIX}-${SUFFIXES[$i]}.txt"
  rm -f "$out" "${out}.dead" "${out}.dead.log" "${out}.log" "${out}.running"
  # Who runs it, since when, and for how long at most: an empty marker said
  # "alive" and nothing else, and a judge looking at an empty answer beside it
  # could not tell three minutes in from thirty (#27). Our pid for now; the
  # backend's own subshell replaces it with its own the moment it starts.
  mark "${out}.running" "$$" "$now" "${TIMEOUTS[$i]}"
done
# The roster last: wait.sh needs it to exist, and by now every marker it will
# look at is there -- published first, a waiter saw a roster with no markers
# and called the run dead before it launched.
printf '%s\n' "${SUFFIXES[@]}" > "${ROSTER}.tmp" && mv -f "${ROSTER}.tmp" "$ROSTER"
rm -f "$LOCK"; trap - EXIT

# And last thing: record how long it took (wait.sh reports it, and #28 is
# about knowing which backend is the slow one), THEN drop the marker, so no
# reader sees "finished" before the time is there.
# A runner that ends with nothing written and no marker (codex exit != 124 with
# an empty stderr) used to be marked NO OUTPUT only by the parent, after EVERY
# backend was done -- a reader in between saw "finished, no answer, no
# reason". Mark it here, in the runner's own subshell, the moment it ends.
finished() { # finished <suffix> <out> <start epoch> <name>
  [ -s "$2" ] || [ -e "${2}.dead" ] || multi_fail_backend "$2" "$4: NO OUTPUT"
  echo "$1 $(( $(date +%s) - $3 ))" >> "$ROSTER"
  rm -f "${2}.running"
}

# All backends start at once. OpenCode spends most of a minute waking up and
# every model takes 30-90s, so anything sequential here is pure wall clock.
pids=""
trap 'multi_ask_terminated 15' TERM
trap 'multi_ask_terminated 2' INT
trap 'multi_ask_terminated 1' HUP
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; model="${MODELS[$i]}"; out="${PREFIX}-${SUFFIXES[$i]}.txt"
  # ONE cd for every backend: each harness reads the tree from its cwd, and
  # per-backend cwd handling is how openrouter/gemini shipped reviewing the
  # caller's directory as an empty diff. A new backend inherits this for free.
  # All -o/log/out paths are absolute (made so above), so nothing lands astray.
  # The runner's timeout and stall come from the config, per backend, and
  # live in the same two variables the runners always read -- set in this
  # backend's own subshell, so one slow codex does not stretch the others.
  type="${TYPES[$i]}"; chain="${CHAINS[$i]}"; t0="$now"
  # A backend inside one of its `avoid` windows (config.toml) is not launched.
  # It is still a participant: its answer file says so and the roster closes
  # it, so a report reads "sat out peak hours", never silence. The verdict was
  # taken once, at resolve time above -- the clock is not re-read per backend.
  if [ -n "${CLOSED[$i]}" ]; then
    multi_fail_backend "$out" "$name: ${CLOSED[$i]}"
    echo "${SUFFIXES[$i]} 0" >> "$ROSTER"; rm -f "${out}.running"
    continue
  fi
  case "$type" in
    codex)
      ( MULTI_BACKEND_TIMEOUT="${TIMEOUTS[$i]}"; started "$out" && cd "$REPO_DIR" \
        && run_codex_one "$out" "${model:-${CODEX_MODEL:-$(first_of "$chain")}}"; finished "${SUFFIXES[$i]}" "$out" "$t0" "$name" ) & ;;
    opencode)
      # Pinned: exactly that model. --model/--fallback: this run's chain.
      # Otherwise the config chain, or, when it is empty, a free model from the
      # catalogue with every other free one as fallback.
      if [ -n "$model" ]; then oc_model="$model"; oc_fallback=""
      elif [ -n "$MODEL" ]; then oc_model="$MODEL"; oc_fallback="$FALLBACK"
      elif [ -n "$chain" ]; then oc_model="$(first_of "$chain")"; oc_fallback="${FALLBACK:-$(rest_csv "$chain")}"
      else
        auto="$(multi_opencode_autodetect 2>/dev/null)" || auto=""
        oc_model="${auto%% *}"; oc_fallback="${auto#* }"; [ "$oc_fallback" != "$auto" ] || oc_fallback=""
        [ -z "$FALLBACK" ] || oc_fallback="$FALLBACK"
      fi
      ( MULTI_BACKEND_TIMEOUT="${TIMEOUTS[$i]}"; MULTI_OPENCODE_STALL="${STALLS[$i]}"; started "$out" && cd "$REPO_DIR" \
        && run_opencode_one "$out" "$oc_model" "$oc_fallback"; finished "${SUFFIXES[$i]}" "$out" "$t0" "$name" ) & ;;
    claude-headless)
      ( MULTI_BACKEND_TIMEOUT="${TIMEOUTS[$i]}"; MULTI_BACKEND_STALL="${STALLS[$i]}"; started "$out" && cd "$REPO_DIR" \
        && multi_run_headless "$name" "$QUESTION" "$out" "$model" "$chain" "${URLS[$i]}" "${KEYENVS[$i]}"; finished "${SUFFIXES[$i]}" "$out" "$t0" "$name" ) & ;;
    gemini)
      ( MULTI_BACKEND_TIMEOUT="${TIMEOUTS[$i]}"; started "$out" && cd "$REPO_DIR" \
        && multi_run_gemini "$name" "$QUESTION" "$out" "${model:-$(first_of "$chain")}" "${KEYENVS[$i]}"; finished "${SUFFIXES[$i]}" "$out" "$t0" "$name" ) & ;;
    *) multi_fail_backend "$out" "$name: unknown backend type '$type'"; rm -f "${out}.running" ;;
  esac
  pids="$pids $!:${SUFFIXES[$i]}"
done
for pb in $pids; do wait "${pb%%:*}"; done

wrote=""; alive=0
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; f="${PREFIX}-${SUFFIXES[$i]}.txt"
  # Whether a backend is alive is decided by the runners' sidecar marker, never
  # by grepping the model's own text: an answer that starts with "codex: NO
  # OUTPUT ..." is a live backend, and parsing model text as status used to
  # read it as dead. An empty file still must never read as an answer.
  # Count only; finished() already marked an empty file NO OUTPUT in the
  # runner's own subshell. Writing here again would land on a newer run that
  # took the prefix the moment the last marker went.
  if [ -s "$f" ] && [ ! -e "${f}.dead" ]; then alive=$((alive+1)); fi
  wrote="$wrote${wrote:+ }$f"
done
echo "wrote: $wrote"
[ "$alive" -gt 0 ]
