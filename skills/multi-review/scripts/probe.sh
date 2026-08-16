#!/usr/bin/env bash
# Setup gate for the mcr plugin. Prints one line per reviewer backend.
# Costs zero model tokens: the skill injects this output as text before the
# model reads the skill body, so no tool call and no cached state are needed.
set -uo pipefail

say() { printf '%s\n' "$*"; }

# --- Codex (required) ---------------------------------------------------
if command -v codex >/dev/null 2>&1; then
  ver="$(codex --version 2>/dev/null | head -1)"
  if timeout 10 codex login status 2>&1 | grep -qi 'logged in'; then
    say "codex: OK — ${ver}"
  else
    say "codex: NOT LOGGED IN — ${ver} (run: codex login)"
  fi
else
  say "codex: MISSING"
fi

# --- OpenCode (optional third reviewer) ---------------------------------
# Model resolution order:
#   1. $MCR_OPENCODE_MODEL           — explicit user override
#   2. first entry of $MCR_OPENCODE_CANDIDATES that `opencode models` lists
#   3. nothing -> reviewer skipped
CANDIDATES="${MCR_OPENCODE_CANDIDATES:-opencode/deepseek-v4-flash-free opencode-go/deepseek-v4-flash}"

if command -v opencode >/dev/null 2>&1; then
  if [ -n "${MCR_OPENCODE_MODEL:-}" ]; then
    say "opencode: OK — ${MCR_OPENCODE_MODEL} (from MCR_OPENCODE_MODEL)"
  else
    available="$(timeout 20 opencode models 2>/dev/null)"
    picked=""
    for m in $CANDIDATES; do
      if printf '%s\n' "$available" | grep -qxF "$m"; then picked="$m"; break; fi
    done
    if [ -n "$picked" ]; then
      say "opencode: OK — ${picked}"
    else
      say "opencode: NO USABLE MODEL (set MCR_OPENCODE_MODEL to one of: $(printf '%s' "$available" | head -5 | tr '\n' ' '))"
    fi
  fi
else
  say "opencode: MISSING (optional — third reviewer will be skipped)"
fi

# --- reviewer model -----------------------------------------------------
# Sonnet by default: a fleet of reviewers is the wrong place to spend the
# expensive model, and the judge (the main thread) is where depth pays off.
# Override per-machine or per-run with MCR_REVIEWER_MODEL.
say "reviewer-model: ${MCR_REVIEWER_MODEL:-sonnet (default)}"

# --- ponytail (optional fourth lens) ------------------------------------
# Not a reviewer backend: a Claude skill that hunts over-engineering only, and
# says so itself. Worth adding as a separate lens, never as a vote on defects.
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
  say "ponytail: absent (optional — simplicity lens will be skipped)"
fi

# --- Repo state ---------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  say "repo: $(git rev-parse --show-toplevel) @ $(git rev-parse --abbrev-ref HEAD)"
  say "dirty-files: $(git status --porcelain --untracked-files=all 2>/dev/null | wc -l)"
else
  say "repo: NOT A GIT REPOSITORY"
fi
