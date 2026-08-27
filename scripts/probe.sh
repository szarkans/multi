#!/usr/bin/env bash
# Everything the skill needs to know before it starts, gathered without the
# model spending a single tool call: this output is injected into SKILL.md
# before the model reads it.
#
# On quotas, honestly: neither CLI reports how much usage is left. `codex
# doctor` reports auth mode and reachability, `opencode stats` reports what was
# already spent, and `opencode providers` reports which credentials exist —
# none of them answer "will the next call succeed". So this probe reports what
# is *available*, and running out is discovered at run time, where the reviewer
# scripts fall back to a free model and then give up with a note.
set -uo pipefail

say() { printf '%s\n' "$*"; }

# Keys and the extra backends. Sourced, not run: this only reads what is
# configured, it does not call anybody.
SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=providers.sh
. "$SELF_DIR/providers.sh"

# The review target, not the process cwd. The skill runs this probe in its own
# bash block, where cwd is the session checkout; the real target may be another
# worktree. Anchor here so the "repo:" line below names what is actually being
# reviewed and a mismatch is visible. Default: cwd.
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "--repo needs a value" >&2; exit 2; }; REPO="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$REPO" ] || cd "$REPO" 2>/dev/null || { echo "--repo is not a directory: $REPO" >&2; exit 2; }

# --- Codex (required) ---------------------------------------------------
if command -v codex >/dev/null 2>&1; then
  ver="$(codex --version 2>/dev/null | head -1)"
  if multi_timeout 10 codex login status 2>&1 | grep -qi 'logged in'; then
    say "codex: OK — ${ver}"
  else
    say "codex: NOT LOGGED IN — ${ver} (run: codex login)"
  fi
else
  say "codex: MISSING"
fi

# --- OpenCode -----------------------------------------------------------
# Model resolution:
#   1. $MULTI_OPENCODE_MODEL           — explicit override, used as-is
#   2. first entry of opencode: in the user's models config, used as-is
#   3. first entry of $MULTI_OPENCODE_CANDIDATES that `opencode models` lists
#   4. nothing -> reviewer skipped
# The default candidate order puts the free model first on purpose: it is the
# one measured working here, and a review is not worth burning paid usage on
# by default. Set MULTI_OPENCODE_MODEL to spend the subscription deliberately.
CANDIDATES="${MULTI_OPENCODE_CANDIDATES:-opencode/deepseek-v4-flash-free opencode-go/deepseek-v4-flash}"

if command -v opencode >/dev/null 2>&1; then
  if [ -n "${MULTI_OPENCODE_MODEL:-}" ]; then
    say "opencode: OK — ${MULTI_OPENCODE_MODEL} (pinned by MULTI_OPENCODE_MODEL)"
  else
    # Hand-edited `key: comma-or-space-separated values` file; # starts a comment.
    # Only opencode is recognized for now. Unknown keys are ignored.
    models_config="${MULTI_MODELS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/multi/models}"
    configured_models=""
    if [ -f "$models_config" ]; then
      config_line=""
      while IFS= read -r config_line || [ -n "$config_line" ]; do
        config_line="${config_line%%#*}"
        case "$config_line" in
          *:*)
            config_key="${config_line%%:*}"
            config_value="${config_line#*:}"
            config_key="$(printf '%s' "$config_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            config_value="$(printf '%s' "$config_value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            config_value="$(printf '%s' "$config_value" | tr ',' ' ')"
            config_value="$(printf '%s' "$config_value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            case "$config_key" in
              opencode) [ -z "$config_value" ] || { configured_models="$config_value"; break; } ;;
            esac
            ;;
        esac
      done < "$models_config"
    fi

    if [ -n "$configured_models" ]; then
      picked=""
      fallback=""
      for m in $configured_models; do
        if [ -z "$picked" ]; then
          picked="$m"
        else
          fallback="${fallback}${fallback:+,}${m}"
        fi
      done
      say "opencode: OK — ${picked}${fallback:+ (fallback: ${fallback})} (from config)"
    else
      # `opencode --pure models` is the whole cost of this probe: 2.9s against 49ms for
      # the codex check, measured 2026-08-20 -- and this probe runs before every
      # single skill invocation. The list is a catalogue, not a live state, so it
      # is cached; a model that disappeared mid-hour is already handled, since the
      # reviewer falls back when its first choice dies. Delete the file or set
      # MULTI_PROBE_CACHE_MIN=0 to force a fresh read.
      models_cache="$MULTI_HOME/opencode-models.cache"
      cache_min="${MULTI_PROBE_CACHE_MIN:-60}"
      available=""
      # `find -mmin` rather than stat: stat's flags differ between GNU and BSD.
      [ "$cache_min" != "0" ] && [ -s "$models_cache" ] \
        && [ -n "$(find "$models_cache" -mmin "-${cache_min}" 2>/dev/null)" ] \
        && available="$(cat "$models_cache")"
      if [ -z "$available" ]; then
        available="$(multi_timeout 20 opencode --pure models 2>/dev/null)"; models_rc=$?
        # Only a run that finished cleanly may be cached. A listing that printed
        # half its models and then timed out is non-empty, and caching it would
        # pin a truncated catalogue for the next hour -- long enough to make the
        # probe report "no usable model" on a machine where the model exists.
        if [ "$models_rc" -eq 0 ] && [ -n "$available" ]; then
          mkdir -p "$MULTI_HOME" 2>/dev/null
          # Written elsewhere and renamed: a reader in another session must never
          # catch this file mid-write and cache-hit on half a list for an hour.
          cache_tmp="${models_cache}.$$"
          if printf '%s\n' "$available" > "$cache_tmp" 2>/dev/null; then
            mv -f "$cache_tmp" "$models_cache" 2>/dev/null || rm -f "$cache_tmp"
          fi
        fi
      fi
      picked=""
      for m in $CANDIDATES; do
        printf '%s\n' "$available" | grep -qxF "$m" && { picked="$m"; break; }
      done
      # The fallback chain is what the reviewer walks when earlier choices die
      # mid-run — running out of paid usage being the usual reason. `opencode/`
      # is the free channel; `opencode-go/` is not. Keep every free model in the
      # catalogue's order, except the already-selected primary.
      fallback=""
      free_models="$(printf '%s\n' "$available" | grep '^opencode/')"
      for m in $free_models; do
        [ "$m" = "$picked" ] || fallback="${fallback}${fallback:+,}${m}"
      done
      if [ -n "$picked" ]; then
        say "opencode: OK — ${picked}${fallback:+ (fallback: ${fallback})}"
      else
        say "opencode: NO USABLE MODEL — none of [$CANDIDATES] is available; set MULTI_OPENCODE_MODEL to one of: $(printf '%s' "$available" | head -5 | tr '\n' ' ')"
      fi
    fi
  fi
else
  say "opencode: MISSING (third reviewer will be skipped)"
fi

# --- OpenRouter ---------------------------------------------------------
# A key here is the widest single upgrade available: OpenRouter speaks the
# Anthropic protocol, so every family it carries can be driven by Claude Code
# itself. Reported as configured / not configured only — actually checking the
# key costs a network round trip, which scripts/setup.sh status does and this does not.
if multi_have_openrouter; then
  say "openrouter: OK — ${MULTI_OPENROUTER_MODEL} first, then falls back through busy free pools (MULTI_OPENROUTER_MODELS to change, or ask.sh --backend openrouter:model for one run)"
elif [ -n "${OPENROUTER_API_KEY:-}" ]; then
  say "openrouter: KEY SET BUT claude CLI MISSING"
else
  say "openrouter: NOT CONFIGURED (ask the user to run scripts/setup.sh set OPENROUTER_API_KEY in their own terminal (it prompts for the key) — one key adds every model family)"
fi

# --- Gemini -------------------------------------------------------------
# Its own CLI, not Claude Code: Google exposes no Anthropic-compatible
# endpoint, and the CLI spends the key's free daily quota rather than paying a
# router for the same model.
if multi_have_gemini; then
  say "gemini: OK${MULTI_GEMINI_MODEL:+ — $MULTI_GEMINI_MODEL}"
elif [ -n "${GEMINI_API_KEY:-}" ]; then
  say "gemini: KEY SET BUT gemini CLI MISSING (npm i -g @google/gemini-cli)"
elif command -v gemini >/dev/null 2>&1; then
  say "gemini: NOT CONFIGURED (CLI present, no GEMINI_API_KEY — ask the user to run scripts/setup.sh set GEMINI_API_KEY in their own terminal (it prompts for the key))"
else
  say "gemini: MISSING"
fi

# --- ponytail -----------------------------------------------------------
# Globs rather than `find`: a full walk of the plugin cache costs seconds, and
# this probe runs on every invocation.
pony=""
for g in \
  "$HOME"/.claude/plugins/cache/*/*/*/skills/ponytail-review \
  "$HOME"/.claude/skills/*/skills/ponytail-review \
  "$HOME"/.claude/skills/ponytail-review \
  ./.claude/skills/ponytail-review
do
  [ -d "$g" ] && { pony="$g"; break; }
done
if [ -n "$pony" ]; then
  say "ponytail: OK — skill ponytail:ponytail-review available"
else
  say "ponytail: MISSING (the simplicity lens will be skipped)"
fi

# --- reviewer model -----------------------------------------------------
say "reviewer-model: ${MULTI_REVIEWER_MODEL:-sonnet (default)}"

# --- where we are -------------------------------------------------------
# Raw material for guessing what the user means, not a decision. This skill is
# normally reached at the end of a session, when "review my work" means the
# branch or the working tree; the numbers below are how you tell which.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  say "repo: $(git rev-parse --show-toplevel) @ ${branch}"
  say "dirty-files: $(git status --porcelain --untracked-files=all 2>/dev/null | wc -l)"
  base=""
  for b in main master; do
    git show-ref --verify --quiet "refs/heads/$b" && { base="$b"; break; }
  done
  if [ -n "$base" ] && [ "$branch" != "$base" ]; then
    say "commits-ahead-of-${base}: $(git rev-list --count "${base}..HEAD" 2>/dev/null || echo '?')"
  fi
else
  say "repo: NOT A GIT REPOSITORY"
fi
