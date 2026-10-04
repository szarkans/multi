# Kilo Code — a second free floor

What it adds: another free reviewer family. Kilo Code (`kilo`) is a fork of
OpenCode with its own free models; they work without an account or key.

## Steps

1. Install, if the probe said MISSING:
   ```
   npm install -g @kilocode/cli
   ```
   No signup, no key — free models work immediately. If the user is already
   logged in to Kilo, that account is used as is.

2. Add it to the config (it is NOT in the built-in config), only if config.toml
   has no `type = "kilo"` backend yet (a second `[backends.kilo]` table breaks
   the config):
   ```toml
   [backends.kilo]
   type = "kilo"
   models = []        # empty = a free kilo/...:free model from `kilo models`
   ```
   and put `"kilo"` into the profile they want it in (`references/config.md`).

## Models

- `kilo/<vendor>/<model>:free` — free. The same quality warning as OpenCode's
  free channel applies: weaker and flakier than paid.
- `kilo/kilo-auto/*` and `kilo/openrouter/*` are routers: the answering model
  varies per call. Never pick them automatically; pin one only if the user asks.
- Big free models (nemotron) can queue for minutes on a shared pool; the stall
  setting (`stall = N` in the backend table) covers a model that says nothing.
