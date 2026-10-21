# Antigravity (agy) — Google's agent CLI as a reviewer

What it adds: one more reviewer family through the Google Antigravity CLI
(`agy`), with the models its account offers (Claude and Gemini ids).

## Steps

1. Install the Antigravity CLI if the probe said MISSING, then sign in: the
   user runs `agy` once in their own terminal. There is no key to store; the
   sign-in token stays in `~/.gemini/antigravity-cli/`. The probe says
   NOT LOGGED IN until that is done.

2. Add it to the config (it is NOT in the built-in config), only if config.toml
   has no `type = "agy"` backend yet:
   ```toml
   [backends.agy]
   type = "agy"
   models = ["claude-sonnet-4-6"]   # at most one model
   ```
   and put `"agy"` into the profile they want it in (`references/config.md`).

## Models

- Only ids that `agy models` lists, e.g. `claude-sonnet-4-6`,
  `claude-opus-4-6-thinking`, `gemini-3.8-flash-high`. One model per backend;
  add a second `[backends.<name>]` with `type = "agy"` for another.
- `effort` is not supported: multi never passes `--effort` to agy.

## Read-only

agy is not read-only on its own. multi runs it with a clean environment (the
keys from providers.env do not reach it) and a fresh HOME per run (under
`$MULTI_HOME/agy-home`, removed afterwards): sandboxed settings, a
PreToolUse hook (`scripts/agy-gate.py`) that denies anything but reading files
inside the repository and one read-only shell command, and only the sign-in
token linked from the user's HOME. The user's own `~/.gemini/config` (skills,
hooks) is not loaded. The
reviewed repo's `.agent/`, `.agents/`, AGENTS.md and GEMINI.md are stripped
from the copy agy reads.

## Training

Verdict `yes`: by the Antigravity terms, interactions may be used to improve
Google models. If the user's account opted out in Antigravity settings, set
`trains = false` under `[backends.agy]`.
