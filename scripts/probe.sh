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

# --- config -------------------------------------------------------------
# Backends, models, endpoints and timeouts come from config.toml; a broken
# file is reported here, before any skill acts on it, and is a hard stop.
if ! CONFIG="$(multi_config check 2>&1)"; then
  say "config: BROKEN — $CONFIG"
  say "config: fix $(multi_config path 2>/dev/null || echo "$MULTI_HOME/config.toml") or delete it to get the built-in default"
  BACKENDS=""
else
  say "$CONFIG"
  BACKENDS="$(multi_config backends)" || { say "config: BROKEN — backends could not be listed"; BACKENDS=""; }
fi
# The pre-config opencode list is not read any more; say so once, with the
# one edit that carries it over.
for legacy in "$MULTI_HOME/models" "${XDG_CONFIG_HOME:-$HOME/.config}/multi/models"; do
  [ -f "$legacy" ] || continue
  say "models-config: LEGACY — $legacy is no longer read; put its list under [backends.opencode] models = [...] in $(multi_config path) and delete the file"
  break
done

# One line per configured backend. Codex above is the exception because it is
# required; everything here is optional and reported as configured / not.
# Keys are reported present or absent only — actually checking one costs a
# network round trip, which scripts/setup.sh status does and this does not.
while IFS="$(printf '\t')" read -r name type chain url keyenv timeout stall; do
  [ -n "$name" ] || continue
  [ -n "$stall" ] || { say "config: BROKEN — unexpected backends line shape"; break; }
  [ "$chain" != "-" ] || chain=""
  eval "key=\${$keyenv:-}"
  configured_models=""
  case "$type" in
    codex)
      if command -v codex >/dev/null 2>&1; then
        ver="$(codex --version 2>/dev/null | head -1)"
        if multi_timeout 10 codex login status 2>&1 | grep -qi 'logged in'; then
          say "$name: OK — ${ver}${chain:+ — $chain}"
        else
          say "$name: NOT LOGGED IN — ${ver} (run: codex login)"
        fi
      else
        say "$name: MISSING"
      fi ;;
    opencode)
      if ! command -v opencode >/dev/null 2>&1; then
        say "$name: MISSING (third reviewer will be skipped)"
      elif [ -n "$chain" ]; then
        set -- $chain; picked="$1"; shift; fallback="$(printf '%s' "$*" | tr ' ' ',')"
        say "$name: OK — ${picked}${fallback:+ (fallback: ${fallback})} (from config)"
        configured_models="$chain"
      else
        # Model resolution with an empty list: first candidate that `opencode
        # models` lists, every other free model as fallback; nothing -> skipped.
        # The default candidate order puts the free model first on purpose: it is
        # the one measured working here, and a review is not worth burning paid
        # usage on by default. List a paid model in config.toml to spend it.
        auto="$(multi_opencode_autodetect)" || auto=""
        picked="${auto%% *}"; fallback="${auto#* }"; [ "$fallback" != "$auto" ] || fallback=""
        if [ -n "$picked" ]; then
          say "$name: OK — ${picked}${fallback:+ (fallback: ${fallback})}"
        else
          say "$name: NO USABLE MODEL — none of [$MULTI_OPENCODE_CANDIDATES] is available; set models under [backends.$name] in config.toml to one of: $(multi_opencode_catalogue | head -5 | tr '\n' ' ')"
        fi
        configured_models=""
      fi
      # The paid Go channel showing up means a subscription is available, and the
      # setup skill keys its "spend it deliberately" offer on this line. The
      # config and the catalogue cache are the two free-to-read witnesses.
      # ponytail: the cache is only ever WRITTEN by the autodetect path, so a
      # user who listed free opencode/* models in the config before ever probing
      # without one never sees this line -- the exact user it is for. Closing
      # that needs a real `opencode --pure models` call on the config path, and
      # this probe runs before every skill invocation; 2.9s each time is the
      # price, and it was not judged worth it.
      paid_seen="$(printf '%s\n' "$configured_models" | tr ' ' '\n')"
      [ -s "$MULTI_HOME/opencode-models.cache" ] \
        && paid_seen="$paid_seen
$(cat "$MULTI_HOME/opencode-models.cache" 2>/dev/null)"
      if grep -q '^opencode-go/' <<<"$paid_seen"; then
        say "opencode-paid-channel: available (opencode-go/* listed)"
      fi
      ;;
    claude-headless)
      # A key here is the widest single upgrade available: any Anthropic-
      # compatible endpoint can be driven by Claude Code itself.
      if [ -n "$key" ] && command -v claude >/dev/null 2>&1; then
        say "$name: configured (key $keyenv set, not checked here — /multi:setup status verifies it) — endpoint $url, models: $chain (first live pool wins; ask.sh --backend $name:<model> pins one)"
      elif [ -n "$key" ]; then
        say "$name: KEY SET BUT claude CLI MISSING"
      else
        say "$name: NOT CONFIGURED (ask the user to run scripts/setup.sh set $keyenv in their own terminal (it prompts for the key) — endpoint $url)"
      fi
      ;;
    gemini)
      # Its own CLI, not Claude Code: Google exposes no Anthropic-compatible
      # endpoint, and the CLI spends the key's free daily quota rather than
      # paying a router for the same model.
      if [ -n "$key" ] && command -v gemini >/dev/null 2>&1; then
        say "$name: configured (key $keyenv set, not checked here — /multi:setup status verifies it)${chain:+ — $chain}"
      elif [ -n "$key" ]; then
        say "$name: KEY SET BUT gemini CLI MISSING (npm i -g @google/gemini-cli)"
      elif command -v gemini >/dev/null 2>&1; then
        say "$name: NOT CONFIGURED (CLI present, no $keyenv — ask the user to run scripts/setup.sh set $keyenv in their own terminal (it prompts for the key))"
      else
        say "$name: MISSING"
      fi
      ;;
  esac
done <<EOF
$BACKENDS
EOF

# --- other AI CLIs (not reviewers yet) ----------------------------------
# Raw detection for the setup skill: what else on this machine could one day
# hold a quota. Reported only — nothing here configures or calls them.
others=""
for c in antigravity aider goose droid amp cursor-agent; do
  command -v "$c" >/dev/null 2>&1 && others="${others}${others:+, }$c"
done
if [ -n "$others" ]; then
  say "other-ai-clis: $others (detected only — not usable as reviewers yet)"
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
