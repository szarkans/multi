#!/usr/bin/env bash
# Read and write the provider keys, and say honestly which ones work.
#
#   setup.sh status                 what is configured, and does it still work
#   setup.sh set OPENROUTER_API_KEY sk-or-v1-...
#   setup.sh set GEMINI_API_KEY AIza...
#   setup.sh unset GEMINI_API_KEY
#
# `status` is the only command that touches the network. It uses curl rather
# than launching an agent, because both agents retry an auth failure silently:
# a rejected key looks exactly like a slow model until the timeout kills it.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=providers.sh
. "$SELF_DIR/providers.sh"

usage() { sed -n '2,12p' "$0"; exit 2; }

# Never echoed in full anywhere: a key in a transcript is a leaked key.
mask() { local v="$1"; [ ${#v} -gt 12 ] && printf '%s…%s' "${v:0:8}" "${v: -4}" || printf '****'; }

cmd_status() {
  echo "keys file: $MULTI_PROVIDERS_ENV"
  [ -r "$MULTI_PROVIDERS_ENV" ] || echo "  (does not exist yet — nothing configured)"

  printf 'openrouter: '
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    printf '%s — ' "$(mask "$OPENROUTER_API_KEY")"
    # Report the model that will actually be used, not the one we hoped for:
    # a free pool returning 429 is normal and the runner moves on to the next.
    live="$(multi_pick_openrouter_model)" \
      && echo "OK — will use $live" \
      || echo "ALL POOLS BUSY (429 upstream, not your quota): $MULTI_OPENROUTER_MODELS"
  else
    echo "not configured"
  fi

  printf 'gemini:     '
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    printf '%s — ' "$(mask "$GEMINI_API_KEY")"; multi_check_gemini
  else
    echo "not configured"
  fi

  printf 'codex CLI:    '; command -v codex    >/dev/null 2>&1 && codex --version 2>/dev/null | head -1 || echo "MISSING"
  printf 'opencode CLI: '; command -v opencode >/dev/null 2>&1 && echo present || echo "MISSING"
  printf 'gemini CLI:   '; command -v gemini   >/dev/null 2>&1 && echo present || echo "MISSING"
}

cmd_set() {
  local name="$1" value="${2:-}"
  case "$name" in
    OPENROUTER_API_KEY|GEMINI_API_KEY|MULTI_OPENROUTER_MODEL|MULTI_OPENROUTER_MODELS|MULTI_GEMINI_MODEL|MULTI_OPENCODE_MODEL) ;;
    *) echo "refusing to set unknown variable: $name" >&2; exit 2 ;;
  esac
  [ -n "$value" ] || { echo "empty value for $name" >&2; exit 2; }

  mkdir -p "$(dirname "$MULTI_PROVIDERS_ENV")"
  touch "$MULTI_PROVIDERS_ENV"
  # 600 before anything is written, not after: a key must never exist on disk
  # world-readable, not even for the moment between write and chmod.
  chmod 600 "$MULTI_PROVIDERS_ENV" 2>/dev/null

  local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
  grep -v "^export ${name}=" "$MULTI_PROVIDERS_ENV" > "$tmp" 2>/dev/null
  # Single quotes and a literal-quote escape: keys are opaque strings and one
  # of them will eventually contain a character the shell cares about.
  printf "export %s='%s'\n" "$name" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")" >> "$tmp"
  mv "$tmp" "$MULTI_PROVIDERS_ENV"
  chmod 600 "$MULTI_PROVIDERS_ENV"
  echo "set $name ($(mask "$value")) in $MULTI_PROVIDERS_ENV"
}

cmd_unset() {
  local name="$1"
  [ -f "$MULTI_PROVIDERS_ENV" ] || { echo "nothing to unset"; return 0; }
  local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
  grep -v "^export ${name}=" "$MULTI_PROVIDERS_ENV" > "$tmp" 2>/dev/null
  mv "$tmp" "$MULTI_PROVIDERS_ENV"; chmod 600 "$MULTI_PROVIDERS_ENV"
  echo "removed $name"
}

case "${1:-}" in
  status) cmd_status ;;
  set)    [ $# -ge 3 ] || usage; cmd_set "$2" "$3" ;;
  unset)  [ $# -ge 2 ] || usage; cmd_unset "$2" ;;
  *) usage ;;
esac
