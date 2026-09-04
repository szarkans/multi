#!/usr/bin/env bash
# Read and write the provider keys, and say honestly which ones work.
#
#   setup.sh status                 what is configured, and does it still work
#   setup.sh set OPENROUTER_API_KEY   reads the key from stdin, never echoed
#   setup.sh set GEMINI_API_KEY       same; or pipe it: printf %s "$k" | ...
#   setup.sh unset GEMINI_API_KEY
#   setup.sh init                     write the default config.toml to edit
#
# Which names `set` accepts: the api_key_env of every backend in config.toml
# (OPENROUTER_API_KEY for [backends.openrouter] unless it says otherwise).
# Models, endpoints and timeouts are not keys — they are edited in the file.
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
  echo "config:    $(multi_config path)"
  if ! multi_config check >/dev/null 2>"$TMPERR"; then
    echo "  BROKEN — $(cat "$TMPERR")"; echo "  fix it, or delete it to get the built-in default"; return 2
  fi
  [ -f "$(multi_config path)" ] || echo "  (does not exist — built-in default; 'setup.sh init' writes it out to edit)"

  local name type chain url keyenv timeout stall key live
  while IFS="$(printf '\t')" read -r name type chain url keyenv timeout stall; do
    [ -n "$name" ] || continue
    [ -n "$stall" ] || { echo "config.py backends: unexpected line shape" >&2; break; }
    [ "$chain" != "-" ] || chain=""
    eval "key=\${$keyenv:-}"
    printf '%-12s' "$name:"
    case "$type" in
      claude-headless)
        if [ -n "$key" ]; then
          # A custom endpoint changes what the check below actually talks to —
          # say so, or a 9router/z.ai user reads the name and doubts their key.
          [ "$url" = "https://openrouter.ai/api" ] || printf 'endpoint %s — ' "$url"
          printf '%s — ' "$(mask "$key")"
          # Report the model that will actually be used, not the one we hoped for:
          # a free pool returning 429 is normal and the runner moves on to the next.
          # shellcheck disable=SC2086
          live="$(multi_pick_live_model "$url" "$key" $chain)" \
            && echo "OK — will use $live" \
            || echo "ALL POOLS BUSY or BAD KEY — none of [$chain] answered at $url"
        else
          echo "not configured (setup.sh set $keyenv)"
        fi ;;
      gemini)
        if [ -n "$key" ]; then printf '%s — ' "$(mask "$key")"; multi_check_gemini "$key"
        else echo "not configured (setup.sh set $keyenv)"; fi ;;
      codex)    command -v codex >/dev/null 2>&1 && codex --version 2>/dev/null | head -1 || echo "CLI MISSING" ;;
      opencode) command -v opencode >/dev/null 2>&1 && echo "CLI present${chain:+ — $chain}" || echo "CLI MISSING" ;;
    esac
  done <<EOF
$(multi_config backends)
EOF
  printf 'gemini CLI:   '; command -v gemini   >/dev/null 2>&1 && echo present || echo "MISSING"
}

# The variables a backend reads its key from, per config.toml — the only names
# `set` accepts, so a typo cannot store a key nothing will ever read.
# Only the types that read a key: a stored CODEX_API_KEY would be a secret
# nothing ever uses.
key_names() { multi_config backends | awk -F'\t' '$2=="claude-headless"||$2=="gemini"{print $5}' | sort -u | tr '\n' ' '; }

cmd_set() {
  local name="$1" value="${2:-}"
  local known; known=" $(key_names)"
  case "$known" in
    *" $name "*) ;;
    *) case "$name" in
         MULTI_*) echo "refusing to set $name: models, endpoints and timeouts live in $(multi_config path) now — edit the file" >&2 ;;
         *) echo "refusing to set unknown variable: $name (a backend in config.toml reads one of:$known)" >&2 ;;
       esac; exit 2 ;;
  esac

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

TMPERR="$(mktemp)"; trap 'rm -f "$TMPERR"' EXIT
case "${1:-}" in
  status) cmd_status ;;
  init)   multi_config init ;;
  set)    [ $# -ge 2 ] || usage; cmd_set "$2" "${3:-}" ;;
  unset)  [ $# -ge 2 ] || usage; cmd_unset "$2" ;;
  *) usage ;;
esac
