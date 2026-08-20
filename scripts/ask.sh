#!/usr/bin/env bash
# Put one question to Codex and OpenCode at the same time and write each answer
# to its own file. No review prompt, no parsing, no judging — whatever the
# question is, the answers come back raw.
#
#   ask.sh --question "is a channel or a mutex better here?" --out-prefix "$RUN/ask"
#   ask.sh --question-file "$RUN/prompt.md" --out-prefix "$RUN/done" --effort high
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
# name, same as before name:model existed.
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
# Both run read-only: they can read the repository to answer, and cannot change
# it. Anything that needs to actually execute is the caller's job.
#
# Notes for maintainers:
#   --pure skips the user's OpenCode plugins and --auto pre-approves tool calls;
#   without them a heavy custom default agent can hang the run indefinitely.
#   OpenCode spends roughly a minute on cold start, so the two backends are
#   always launched together rather than in sequence.
set -uo pipefail

# Keys, the child-process isolation and the non-CLI backends all live here.
SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=providers.sh
. "$SELF_DIR/providers.sh"

QUESTION=""; QFILE=""; PREFIX=""; EFFORT=medium; MODEL="${MULTI_OPENCODE_MODEL:-}"; FALLBACK=""; CODEX_MODEL=""; BACKEND=both
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
    --codex-model)   need $# "$1"; CODEX_MODEL="$2"; shift 2 ;;
    --backend)       need $# "$1"; BACKEND="$2"; shift 2 ;;
    --or-model)      need $# "$1"; OR_MODEL="$2"; shift 2 ;;
    --gemini-model)  need $# "$1"; MULTI_GEMINI_MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PREFIX" ] || { echo "--out-prefix is required" >&2; exit 2; }
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
  "$py" "$SELF_DIR/opencode-report.py" "$1" --out "$2" --calls "${2}.calls" --model "$3" 2>/dev/null
}

run_codex_one() {
  local out="$1" model="$2" rc=0
  command -v codex >/dev/null 2>&1 || { echo "codex: MISSING" > "$out"; return 0; }
  # A hung CLI used to block the `wait` below forever, and the caller — usually
  # Claude Code's own bash tool — killed the whole script instead, so every
  # other backend's answer died with it.
  multi_timeout "$MULTI_BACKEND_TIMEOUT" codex exec \
    ${model:+-m "$model"} \
    -s read-only \
    -c model_reasoning_effort="$EFFORT" \
    -o "$out" \
    "$QUESTION" >/dev/null 2>"${out}.log"
  rc=$?
  # stderr used to go to /dev/null, so a codex that failed left "NO OUTPUT" and
  # nothing to go on. The openrouter path keeps a .log for exactly this reason.
  [ -s "$out" ] || [ "$rc" -ne 124 ] || echo "codex: TIMEOUT after ${MULTI_BACKEND_TIMEOUT}s" > "$out"
  [ -s "$out" ] || [ ! -s "${out}.log" ] || echo "codex: NO OUTPUT — exit=$rc (stderr in ${out}.log)" > "$out"
}

run_opencode_one() {
  local out="$1" model="$2" fallback="$3"
  command -v opencode >/dev/null 2>&1 || { echo "opencode: MISSING" > "$out"; return 0; }
  [ -n "$model" ] || { echo "opencode: NO MODEL (set --model or MULTI_OPENCODE_MODEL)" > "$out"; return 0; }
  # --format json rather than the terminal transcript: the transcript mixes the
  # model's answer with every file it opened, and the reader downstream cannot
  # tell those apart. The JSON events can. opencode-report.py turns them into
  # what it did, then what it said.
  local raw="${out}.jsonl" used="$model" rc=0 rrc=0
  multi_timeout "$MULTI_BACKEND_TIMEOUT" opencode run --pure --auto --format json \
    -m "$model" --dir . "$QUESTION" > "$raw" 2>&1; rc=$?
  render_opencode "$raw" "$out" "$used"; rrc=$?

  # No answer means the run did not happen: exhausted usage, an expired
  # subscription, a model that hangs. Neither CLI can be asked about remaining
  # quota beforehand, so this is where it is discovered.
  if [ "$rrc" = 3 ] && [ "$rc" -ne 124 ] && [ -n "$fallback" ] && [ "$fallback" != "$model" ]; then
    echo "[multi] $model produced no answer (exit $rc) — retrying on $fallback" >&2
    used="$fallback"
    multi_timeout "$MULTI_BACKEND_TIMEOUT" opencode run --pure --auto --format json \
      -m "$fallback" --dir . "$QUESTION" > "$raw" 2>&1; rc=$?
    render_opencode "$raw" "$out" "$used"; rrc=$?
  fi

  if [ "$rc" -eq 124 ]; then
    # Checked before the output is accepted: opencode prints its first event
    # within a second, so a run that hangs afterwards still leaves a file.
    echo "opencode: TIMEOUT after ${MULTI_BACKEND_TIMEOUT}s — model=$used (partial capture in $raw)" > "$out"
  elif [ "$rrc" = 3 ]; then
    echo "opencode: NO ANSWER — model=$used exit=$rc — it ran but said nothing; what it did is in ${out}.calls" > "$out"
  elif [ "$rrc" = 2 ] || [ "$rrc" = 4 ]; then
    local why="an opencode without --format json"; [ "$rrc" = 4 ] && why="no python3 on this machine"
    { echo "opencode: RAW CAPTURE ONLY — model=$used exit=$rc ($why)"
      cat "$raw" 2>/dev/null
    } > "$out"
  elif [ ! -s "$out" ]; then
    echo "opencode: NO OUTPUT — model=$used exit=$rc" > "$out"
  fi
  [ "$used" = "$model" ] || echo "[multi] answered by fallback model $used" >> "$out"
}

run_openrouter_one() { multi_run_openrouter "$QUESTION" "$1" "$2"; }
run_gemini_one()     { multi_run_gemini     "$QUESTION" "$1" "$2"; }

# All backends start at once. OpenCode spends most of a minute waking up and
# every model takes 30-90s, so anything sequential here is pure wall clock.
pids=""
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; model="${MODELS[$i]}"; out="${PREFIX}-${SUFFIXES[$i]}.txt"
  case "$name" in
    codex)      run_codex_one      "$out" "${model:-$CODEX_MODEL}"        & ;;
    opencode)   run_opencode_one   "$out" "${model:-$MODEL}" "$FALLBACK"  & ;;
    openrouter) run_openrouter_one "$out" "${model:-$OR_MODEL}"           & ;;
    gemini)     run_gemini_one     "$out" "${model:-$MULTI_GEMINI_MODEL}" & ;;
  esac
  pids="$pids $!:${SUFFIXES[$i]}"
done
for pb in $pids; do wait "${pb%%:*}"; done

wrote=""; alive=0
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; f="${PREFIX}-${SUFFIXES[$i]}.txt"
  # An empty file must never read as an answer: say who did not run.
  [ -s "$f" ] || echo "${name}: NO OUTPUT" > "$f"
  grep -qiE "^${name}: (NO OUTPUT|MISSING|NO KEY|TIMEOUT|NO MODEL)" "$f" || alive=$((alive+1))
  wrote="$wrote${wrote:+ }$f"
done
echo "wrote: $wrote"
[ "$alive" -gt 0 ]
