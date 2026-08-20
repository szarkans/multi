#!/usr/bin/env bash
# Shared provider plumbing: where the keys live, how to reach a model that is
# not one of the CLIs, and how to tell a working key from a broken one.
#
# Sourced, never executed. Everything here is a function or a variable.
#
# Two facts drove this file, both measured (2026-08-19):
#
#   1. OpenRouter really does speak the Anthropic protocol at
#      https://openrouter.ai/api — POST /v1/messages with a bad key returns 401
#      in 0.3s. So an OpenRouter model can be driven by Claude Code itself,
#      with no proxy: same agent loop, different weights.
#
#   2. Claude Code does NOT fail fast on a bad key. It retries silently and
#      produces no output at all — 60s and still going. So a key is always
#      validated with curl (instant, unambiguous), never by launching the
#      agent, and every child process gets a hard timeout.

# --- timeout, portably --------------------------------------------------
# `timeout` is GNU coreutils and is NOT on a stock macOS — Homebrew's coreutils
# installs it as `gtimeout`, and plenty of machines have neither. That matters
# more than it looks: `timeout 10 codex login status | grep -qi 'logged in'`
# does not fail loudly when the binary is missing. The shell writes
# "command not found" to stderr, grep reads an empty stdin, and the probe
# concludes the user is NOT LOGGED IN — on a machine where Codex is perfectly
# logged in. The review skill then hits its own gate ("no Codex → stop") and
# the whole plugin refuses to run.
#
# So: real timeout if there is one, otherwise run it ourselves. The fallback
# is not "skip the timeout" — providers below rely on it, and the note under
# multi_run_openrouter is exactly why: Claude Code does not fail fast on a bad
# key, it retries silently, and without a hard limit that call never returns.
if command -v timeout >/dev/null 2>&1; then
  multi_timeout() { command timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  multi_timeout() { command gtimeout "$@"; }
else
  multi_timeout() {
    local secs="$1"; shift
    # The watchdog leaves a marker before it kills, because the caller has to
    # tell "timed out" from "died on its own": multi_run_openrouter keys its
    # "the key was probably rejected" message on exit 124, which is what GNU
    # timeout returns and what a bare `wait` after a SIGTERM does not (143).
    local flag="${TMPDIR:-/tmp}/multi-timeout.$$.${RANDOM}"
    rm -f "$flag"
    "$@" &
    local pid=$!
    # Sleeping in one-second steps rather than one long sleep: when the command
    # finishes early the watchdog notices and exits, instead of a `sleep 300`
    # sitting in the process table for five minutes after the call returned.
    (
      local n=0
      while [ "$n" -lt "$secs" ]; do
        sleep 1
        kill -0 "$pid" 2>/dev/null || exit 0
        n=$((n+1))
      done
      : > "$flag"
      kill -TERM "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    local watcher=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    [ -e "$flag" ] && rc=124
    rm -f "$flag"
    kill -TERM "$watcher" >/dev/null 2>&1
    wait "$watcher" 2>/dev/null
    return "$rc"
  }
fi

MULTI_HOME="${MULTI_HOME:-$HOME/.claude/multi}"
MULTI_PROVIDERS_ENV="${MULTI_PROVIDERS_ENV:-$MULTI_HOME/providers.env}"

# Keys live outside the plugin on purpose: the plugin directory is a git clone,
# and a key committed once is a key leaked forever.
# shellcheck disable=SC1090
[ -r "$MULTI_PROVIDERS_ENV" ] && . "$MULTI_PROVIDERS_ENV"

# A child `claude` must not inherit this machine's config. Without an isolated
# config dir every reviewer would drag in the user's hooks, MCP servers, plugins
# and session memory — minutes of startup and a pile of borrowed context that
# has nothing to do with the question.
MULTI_CHILD_HOME="${MULTI_CHILD_HOME:-$MULTI_HOME/child-home}"

MULTI_OPENROUTER_MODEL="${MULTI_OPENROUTER_MODEL:-z-ai/glm-5.2:free}"
# A `:free` model is not a queue you are in — it is a shared upstream pool, and
# when it is busy every key gets HTTP 429 regardless of credit. Measured
# 2026-08-20: the default model was 429 while five other free models answered
# in the same second. So the model is CHOSEN at run time, not assumed, and one
# dead pool costs a second instead of the whole backend.
MULTI_OPENROUTER_FALLBACKS="${MULTI_OPENROUTER_FALLBACKS:-poolside/laguna-s-2.1:free nvidia/nemotron-3-super-120b-a12b:free cohere/north-mini-code:free openai/gpt-oss-20b:free}"
# The one list callers and this file actually walk, preferred model first.
# MULTI_OPENROUTER_MODEL and MULTI_OPENROUTER_FALLBACKS above still work as
# overrides — if providers.env sets either, this list is built from them, same
# as before this variable existed. Set MULTI_OPENROUTER_MODELS directly to
# skip that and pin the exact order.
MULTI_OPENROUTER_MODELS="${MULTI_OPENROUTER_MODELS:-$MULTI_OPENROUTER_MODEL $MULTI_OPENROUTER_FALLBACKS}"
MULTI_GEMINI_MODEL="${MULTI_GEMINI_MODEL:-}"   # empty = whatever the CLI defaults to
MULTI_BACKEND_TIMEOUT="${MULTI_BACKEND_TIMEOUT:-300}"
# A review is a different job from a question: it reads a diff, opens files and
# thinks at whatever --effort was asked for, so the same 300s that is generous
# for /multi:ask would cut real reviews off mid-thought. This one exists to stop
# a hung CLI, not to pace a slow one.
MULTI_REVIEW_TIMEOUT="${MULTI_REVIEW_TIMEOUT:-900}"

# --- availability -------------------------------------------------------
# Cheap and local: is there a key and a binary at all. Says nothing about
# whether the key still works — that is what the checks below are for.
multi_have_openrouter() { [ -n "${OPENROUTER_API_KEY:-}" ] && command -v claude >/dev/null 2>&1; }
multi_have_gemini()     { [ -n "${GEMINI_API_KEY:-}" ]     && command -v gemini >/dev/null 2>&1; }

# --- key checks ---------------------------------------------------------
# Both print one word: OK, BAD KEY, or an HTTP code. One second, no tokens
# spent, no ambiguity. This is the only honest way to answer "is my key good",
# because both agents treat an auth failure as something to retry.
# multi_check_openrouter [model] — one word about one model, no tokens spent.
multi_check_openrouter() {
  [ -n "${OPENROUTER_API_KEY:-}" ] || { echo "NO KEY"; return 1; }
  local m="${1:-$MULTI_OPENROUTER_MODEL}" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    https://openrouter.ai/api/v1/messages \
    -H 'content-type: application/json' \
    -H "x-api-key: ${OPENROUTER_API_KEY}" \
    -H 'anthropic-version: 2023-06-01' \
    -d "{\"model\":\"${m}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")"
  case "$code" in
    200) echo "OK" ;;
    401|403) echo "BAD KEY (HTTP $code)"; return 1 ;;
    402) echo "NO CREDIT (HTTP 402)"; return 1 ;;
    429) echo "RATE LIMITED (HTTP 429)"; return 1 ;;
    *) echo "HTTP $code"; return 1 ;;
  esac
}

multi_check_gemini() {
  [ -n "${GEMINI_API_KEY:-}" ] || { echo "NO KEY"; return 1; }
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}")"
  case "$code" in
    200) echo "OK" ;;
    400|401|403) echo "BAD KEY (HTTP $code)"; return 1 ;;
    429) echo "RATE LIMITED (HTTP 429)"; return 1 ;;
    *) echo "HTTP $code"; return 1 ;;
  esac
}

# multi_pick_openrouter_model — first model whose pool answers right now.
# Prints the model name, or nothing if every candidate is down. Costs one
# 1-token request per candidate (~0.3s each), which is far cheaper than
# discovering a dead pool through a 300s agent timeout.
multi_pick_openrouter_model() {
  local m
  for m in $MULTI_OPENROUTER_MODELS; do
    if [ "$(multi_check_openrouter "$m")" = "OK" ]; then printf '%s' "$m"; return 0; fi
  done
  return 1
}

# --- runners ------------------------------------------------------------
# multi_run_openrouter <prompt> <outfile> [model]
# One OpenRouter model driven through Claude Code itself. The agent loop, the
# tools and the prompt handling are identical to a Claude reviewer — only the
# weights differ, which is the entire point.
multi_run_openrouter() {
  local prompt="$1" out="$2" model="${3:-}" rc=0
  local log="${out}.log"
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "openrouter: NO KEY — run scripts/setup.sh set OPENROUTER_API_KEY <key>" > "$out"; return 0
  fi
  # No model pinned by the caller: pick one whose pool is actually up.
  if [ -z "$model" ]; then
    model="$(multi_pick_openrouter_model)" || {
      echo "openrouter: ALL POOLS BUSY — tried $MULTI_OPENROUTER_MODELS (HTTP 429 upstream, not your quota). Retry in a minute or set MULTI_OPENROUTER_MODELS." > "$out"
      return 0
    }
  fi
  mkdir -p "$MULTI_CHILD_HOME"
  # stderr goes to its own file, never into the answer. Claude Code prints an
  # "unrecognized model" banner for every OpenRouter model name; merged in with
  # 2>&1 it made a run that said nothing look like a run that answered.
  # ANTHROPIC_SMALL_FAST_MODEL matters: Claude Code fires background calls at a
  # small model, and the default name does not exist on OpenRouter. Left unset,
  # those calls 404 in the middle of an otherwise fine run.
  CLAUDE_CONFIG_DIR="$MULTI_CHILD_HOME" \
  ANTHROPIC_BASE_URL="https://openrouter.ai/api" \
  ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY" \
  ANTHROPIC_MODEL="$model" \
  ANTHROPIC_SMALL_FAST_MODEL="$model" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
    multi_timeout "$MULTI_BACKEND_TIMEOUT" claude -p "$prompt" \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      > "$out" 2> "$log"
  rc=$?
  if [ ! -s "$out" ]; then
    # A silent run is the signature of a rejected key: Claude Code retries auth
    # failures instead of reporting them, so it dies on the timeout with an
    # empty file. Never let that read as an empty answer.
    if [ "$rc" -eq 124 ]; then
      echo "openrouter: TIMEOUT after ${MULTI_BACKEND_TIMEOUT}s — model=$model. A silent timeout usually means the key was rejected; check with scripts/setup.sh status." > "$out"
    else
      echo "openrouter: NO OUTPUT — model=$model exit=$rc (stderr in $log)" > "$out"
    fi
  else
    echo "[multi] answered by openrouter model $model" >> "$out"
  fi
  return "$rc"
}

# multi_run_gemini <prompt> <outfile> [model]
# Google has no Anthropic-compatible endpoint, so Gemini is not driven through
# Claude Code — it runs in its own CLI, which also keeps the free daily quota
# on the key instead of paying a router for the same model.
multi_run_gemini() {
  local prompt="$1" out="$2" model="${3:-$MULTI_GEMINI_MODEL}" rc=0
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    echo "gemini: NO KEY — run scripts/setup.sh set GEMINI_API_KEY <key>" > "$out"; return 0
  fi
  command -v gemini >/dev/null 2>&1 || { echo "gemini: MISSING (npm i -g @google/gemini-cli)" > "$out"; return 0; }
  GEMINI_API_KEY="$GEMINI_API_KEY" \
    multi_timeout "$MULTI_BACKEND_TIMEOUT" gemini -p "$prompt" \
      ${model:+-m "$model"} --approval-mode plan \
      > "$out" 2>&1
  rc=$?
  if [ ! -s "$out" ]; then
    if [ "$rc" -eq 124 ]; then
      echo "gemini: TIMEOUT after ${MULTI_BACKEND_TIMEOUT}s${model:+ — model=$model}" > "$out"
    else
      echo "gemini: NO OUTPUT${model:+ — model=$model} exit=$rc" > "$out"
    fi
  fi
  return "$rc"
}
