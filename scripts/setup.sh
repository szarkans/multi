#!/usr/bin/env bash
# Read and write the provider keys, and say honestly which ones work.
#
#   setup.sh status                 what is configured, and does it still work
#   setup.sh set OPENROUTER_API_KEY   reads the key from stdin, never echoed
#   setup.sh set GEMINI_API_KEY       same; or pipe it: printf %s "$k" | ...
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
    # A custom endpoint changes what every check below actually talks to —
    # say so, or a 9router/z.ai user reads "openrouter" and doubts their key.
    [ "$MULTI_OPENROUTER_BASE_URL" = "https://openrouter.ai/api" ] \
      || printf 'endpoint %s — ' "$MULTI_OPENROUTER_BASE_URL"
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
    OPENROUTER_API_KEY|GEMINI_API_KEY|MULTI_OPENROUTER_MODEL|MULTI_OPENROUTER_MODELS|MULTI_OPENROUTER_BASE_URL|MULTI_GEMINI_MODEL|MULTI_OPENCODE_MODEL) ;;
    *) echo "refusing to set unknown variable: $name" >&2; exit 2 ;;
  esac

  # Only secrets are worth this dance. A model name is not a secret, and
  # prompting "paste ... (not echoed)" for MULTI_OPENROUTER_MODEL turned a
  # clear usage error into a hidden input.
  case "$name" in
    *_API_KEY) ;;
    *) [ -n "$value" ] || { echo "usage: $(basename "$0") set $name <value>" >&2; exit 2; } ;;
  esac

  # The endpoint decides where OPENROUTER_API_KEY is sent: multi_check_openrouter
  # curls it with an `authorization: Bearer` header and every review run hands it
  # to the child as ANTHROPIC_AUTH_TOKEN. So this one value is as security-
  # relevant as the key itself, and it is the one an injected web page would go
  # for -- the setup skill has WebFetch and researches provider docs. TLS is
  # therefore mandatory, except on the loopback, where a self-hosted router over
  # plain http is a normal setup and nothing leaves the machine.
  if [ "$name" = "MULTI_OPENROUTER_BASE_URL" ]; then
    case "$value" in
      https://*) ;;
      http://localhost|http://localhost/*|http://localhost:*) ;;
      http://127.0.0.1|http://127.0.0.1/*|http://127.0.0.1:*) ;;
      *) echo "refusing $name='$value': must be https:// (http:// only on localhost). Your API key is sent to this host as a Bearer token." >&2; exit 2 ;;
    esac
    echo "note: every OpenRouter call — the key check and every review — will now send OPENROUTER_API_KEY to $value" >&2
  fi

  # Without a value on the command line the key is read from stdin -- typed
  # without echo, or piped in. This is the way to do it: a key in argv is in
  # the shell history, visible in `ps` to every user on the machine, and, when
  # the setup skill runs the command, sitting in the session transcript. The
  # file being chmod 600 afterwards does not undo any of that.
  if [ -z "$value" ]; then
    if [ -t 0 ]; then
      printf 'paste %s (not echoed), then Enter: ' "$name" >&2
      IFS= read -rs value; printf '\n' >&2
    else
      IFS= read -r value
    fi
    # A key piped from a CRLF file (`type key.txt | ...` under Git Bash) keeps a
    # trailing CR, which is stored, invisible, and rejected by the provider
    # while the key looks exactly right in the file.
    value="${value%$'\r'}"
  else
    echo "note: a value passed as an argument stays in your shell history and is visible in ps — '$(basename "$0") set $name' reads it without echoing" >&2
  fi
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

  # chmod is not always obeyed: on MSYS/Git-for-Windows and on mounts like
  # exFAT or a default-mounted NTFS it returns success and changes nothing --
  # measured on Git for Windows, where the file stays -rw-r--r--. The setup
  # skill tells the user the file is owner-only "enforced, not a promise", so
  # where it is not enforced, say so rather than let the promise stand.
  # `ls -l` rather than stat: stat's flags differ between GNU and BSD.
  perms="$(ls -l "$MULTI_PROVIDERS_ENV" 2>/dev/null | cut -c1-10)"
  case "$perms" in
    -rw-------) ;;
    "") echo "warning: could not read the permissions of $MULTI_PROVIDERS_ENV — check by hand that only you can read it" >&2 ;;
    *) echo "warning: $MULTI_PROVIDERS_ENV is $perms, not owner-only — this filesystem ignores chmod (Windows/MSYS, exFAT, some NTFS mounts). Anyone who can read this machine's disk — or, for a group-readable file, anyone in that group — can read the key." >&2 ;;
  esac
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
  set)    [ $# -ge 2 ] || usage; cmd_set "$2" "${3:-}" ;;
  unset)  [ $# -ge 2 ] || usage; cmd_unset "$2" ;;
  *) usage ;;
esac
