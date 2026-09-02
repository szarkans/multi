#!/usr/bin/env bash
# Put one question to Codex and OpenCode at the same time and write each answer
# to its own file. No review prompt, no parsing, no judging — whatever the
# question is, the answers come back raw.
#
#   ask.sh --question "is a channel or a mutex better here?" --out-prefix "$RUN/ask"
#   ask.sh --question-file "$RUN/prompt.md" --out-prefix "$RUN/done" --effort high
#   ask.sh --question-file "$RUN/review.md" --out-prefix "$RUN/review" --timeout 900
#   ask.sh --question "..." --out-prefix /tmp/f2 --backend codex
#   ask.sh --question "..." --out-prefix /tmp/f4 --backend openrouter:x-ai/grok-4.5
#   ask.sh --question "..." --out-prefix /tmp/all --backend all
#   ask.sh --question "..." --out-prefix /tmp/two --backend "openrouter:z-ai/glm-5.2:free,openrouter:x-ai/grok-4.5"
#
# --backend picks who answers: both (the two CLIs, default), all (everything
# configured on this machine), or a comma-separated list of entries. Each
# entry is a backend name — codex, opencode, openrouter, gemini — optionally
# followed by :model. Split on the FIRST colon only, because model names can
# contain colons themselves (z-ai/glm-5.2:free); no colon means the backend's
# usual default (openrouter picks a live free model, opencode uses
# MULTI_OPENCODE_MODEL, ...). The same backend can appear more than once with
# a different model — comparing two OpenRouter models does not need two runs.
# One backend at a time is what lets a caller send a DIFFERENT question to
# each model in parallel instead of the same one to all.
#
# The old per-provider flags (--model, --fallback, --codex-model, --or-model,
# --gemini-model) still work: they set the default model for a bare backend
# name, same as before name:model existed. --fallback accepts a comma-separated
# model list and tries it in order.
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

QUESTION=""; QFILE=""; PREFIX=""; EFFORT=medium; MODEL="${MULTI_OPENCODE_MODEL:-}"; FALLBACK=""; CODEX_MODEL=""; BACKEND=both; REPO=""
# Empty on purpose: an unset OpenRouter model lets the runner pick one whose
# free pool is actually up. Pinning it here sent every run at the same model,
# and a busy upstream pool then became a silent timeout instead of a fallback.
OR_MODEL=""
need() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 2; }; }
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
                     MULTI_BACKEND_TIMEOUT="$2"; shift 2 ;;
    --codex-model)   need $# "$1"; CODEX_MODEL="$2"; shift 2 ;;
    --backend)       need $# "$1"; BACKEND="$2"; shift 2 ;;
    --or-model)      need $# "$1"; OR_MODEL="$2"; shift 2 ;;
    --gemini-model)  need $# "$1"; MULTI_GEMINI_MODEL="$2"; shift 2 ;;
    # Where the CLI reviewers run git and read files: the review target, not the
    # process cwd. Default cwd, so /ask and /adhd (no repo) are unaffected.
    --repo)          need $# "$1"; REPO="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
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
# `both` is the historical default (the two CLIs). `all` is everything this
# machine is set up for. Anything else is a comma-separated list of
# name[:model] entries, so a caller can send a DIFFERENT question — or a
# DIFFERENT model on the same backend — to each in parallel.
case "$BACKEND" in
  both) ENTRIES="codex opencode" ;;
  all)  ENTRIES="codex opencode"
        multi_have_openrouter && ENTRIES="$ENTRIES openrouter"
        multi_have_gemini     && ENTRIES="$ENTRIES gemini" ;;
  *)    ENTRIES="$(printf '%s' "$BACKEND" | tr ',' ' ')" ;;
esac

# Parse each entry into (backend name, model). Split on the FIRST colon only,
# and only when the prefix is a known backend — a model name can contain
# colons itself (z-ai/glm-5.2:free), a bare model name cannot look like one.
NAMES=(); MODELS=(); SUFFIXES=()
for entry in $ENTRIES; do
  case "$entry" in
    codex:*|opencode:*|openrouter:*|gemini:*) name="${entry%%:*}"; model="${entry#*:}" ;;
    *) name="$entry"; model="" ;;
  esac
  case "$name" in
    codex|opencode|openrouter|gemini) ;;
    *) echo "--backend: unknown backend '$name' (codex, opencode, openrouter, gemini, both, all)" >&2; exit 2 ;;
  esac
  # A backend repeated with a different model must not collide on one file.
  # Counted by walking what is already collected. An associative array reads
  # better, but bash 3.2 -- the /bin/bash every stock macOS ships -- has none,
  # and `declare -A` fails there at run time, mid-script, with exit 0: ask.sh
  # printed "declare: -A: invalid option" and the caller saw success.
  seen=0
  for prev in ${NAMES[@]+"${NAMES[@]}"}; do
    [ "$prev" = "$name" ] && seen=$((seen+1))
  done
  suffix="$name"; [ "$seen" -gt 0 ] && suffix="${name}-$((seen+1))"
  NAMES+=("$name"); MODELS+=("$model"); SUFFIXES+=("$suffix")
done

# 0 = there is an answer, 3 = the model said nothing, 2 = the capture is not
# JSON (an opencode older than --format json), 4 = no python3 to read it with.
render_opencode() { # render_opencode <raw> <out> <model>
  local py; py="$(multi_python)" || return 4
  rm -f "${2}.calls" "${2}.error"
  "$py" "$SELF_DIR/opencode-report.py" "$1" --out "$2" --calls "${2}.calls" --model "$3" 2>"${2}.error"
}

run_codex_one() {
  local out="$1" model="$2" rc=0 timeout="$MULTI_CODEX_TIMEOUT"
  if [ "$MULTI_CODEX_TIMEOUT_EXPLICIT" -eq 0 ] && [ "$MULTI_BACKEND_TIMEOUT" -gt "$timeout" ]; then
    timeout="$MULTI_BACKEND_TIMEOUT"
  fi
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
  [ -n "$model" ] || { multi_fail_backend "$out" "opencode: NO MODEL (set --model or MULTI_OPENCODE_MODEL)"; return 0; }
  # --format json rather than the terminal transcript: the transcript mixes the
  # model's answer with every file it opened, and the reader downstream cannot
  # tell those apart. The JSON events can. opencode-report.py turns them into
  # what it did, then what it said.
  local used="$model" rc=0 rrc=0 answered=0 attempted_count=0
  local candidate chain="$model" fallback_models="" attempted="" retry_note="" last_error="" failure_error=""
  local primary_failure="" partial_model="" partial_size=0 best_partial_size=0
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
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
      OPENCODE_CONFIG_CONTENT="$(cat "$SELF_DIR/opencode-readonly.json")" \
      GIT_OPTIONAL_LOCKS=0 \
      multi_timeout "$MULTI_BACKEND_TIMEOUT" opencode run --pure --agent multi-readonly --format json \
      -m "$used" --dir "$REPO_DIR" "$QUESTION" > "$raw" 2>&1; rc=$?
    render_opencode "$raw" "$out" "$used"; rrc=$?
    last_error=""
    [ ! -s "${out}.error" ] || last_error="$(sed -n '1p' "${out}.error")"
    [ -z "$last_error" ] || failure_error="$last_error"
    if [ "$rc" -ne 124 ] && [ "$rrc" -ne 3 ]; then
      answered=1
      break
    fi
    if [ "$attempted_count" -eq 1 ]; then
      if [ "$rc" -eq 124 ]; then
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
    if [ "$rc" -eq 124 ]; then
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
    multi_fail_backend "$out" "opencode: FALLBACK CHAIN EXHAUSTED — tried $attempted; every model ended in TIMEOUT or NO ANSWER (last exit=$rc${failure_error:+; one model reported: $failure_error})${calls_note}" "$raw"
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

run_openrouter_one() { multi_run_openrouter "$QUESTION" "$1" "$2"; }
run_gemini_one()     { multi_run_gemini     "$QUESTION" "$1" "$2"; }

# All backends start at once. OpenCode spends most of a minute waking up and
# every model takes 30-90s, so anything sequential here is pure wall clock.
pids=""
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; model="${MODELS[$i]}"; out="${PREFIX}-${SUFFIXES[$i]}.txt"
  # A reused prefix (loop mode re-reviews with the same $RUN/review) must not
  # let last round's answer stand in for a backend that dies before writing —
  # a stale non-empty file with no .dead marker reads as a live result.
  # The sidecars go too: .dead.log is only ever cleared inside
  # multi_fail_backend, so a round that FAILS then SUCCEEDS leaves last round's
  # stderr tail sitting next to a live answer — the same stale-file confusion
  # this line exists to close, one filename over.
  rm -f "$out" "${out}.dead" "${out}.dead.log" "${out}.log"
  # ONE cd for every backend: each harness reads the tree from its cwd, and
  # per-backend cwd handling is how openrouter/gemini shipped reviewing the
  # caller's directory as an empty diff. A new backend inherits this for free.
  # All -o/log/out paths are absolute (made so above), so nothing lands astray.
  case "$name" in
    codex)      ( cd "$REPO_DIR" && run_codex_one      "$out" "${model:-$CODEX_MODEL}"        ) & ;;
    opencode)   ( cd "$REPO_DIR" && run_opencode_one   "$out" "${model:-$MODEL}" "$FALLBACK"  ) & ;;
    openrouter) ( cd "$REPO_DIR" && run_openrouter_one "$out" "${model:-$OR_MODEL}"           ) & ;;
    gemini)     ( cd "$REPO_DIR" && run_gemini_one     "$out" "${model:-$MULTI_GEMINI_MODEL}" ) & ;;
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
  if [ -s "$f" ] && [ ! -e "${f}.dead" ]; then
    alive=$((alive+1))
  else
    [ -s "$f" ] || multi_fail_backend "$f" "${name}: NO OUTPUT"
  fi
  wrote="$wrote${wrote:+ }$f"
done
echo "wrote: $wrote"
[ "$alive" -gt 0 ]
