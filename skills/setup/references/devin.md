# Devin — Cognition's agent CLI as a reviewer

What it adds: one more reviewer family through the Devin CLI (`devin`), with
the SWE-2 model family its account offers.

## Steps

1. Install the Devin CLI if the probe said MISSING, then sign in: the user
   runs `devin auth login` once in their own terminal. There is no key to
   store; credentials stay in `~/.local/share/devin/`. The probe says
   "no credentials file seen" until that is done.

2. Every installed copy of multi must be >= 1.22.0 first — `type = "devin"`
   in a shared config.toml kills older runners at parse time, and that loud
   ConfigError is deliberate version-skew detection, not a bug.

3. Add it to the config (it is NOT in the built-in config), only if config.toml
   has no `type = "devin"` backend yet:
   ```toml
   [backends.devin]
   type = "devin"
   models = ["swe-2-max"]   # at most one model
   ```
   and put `"devin"` into the profile they want it in (`references/config.md`).

## Models

- Only ids that `devin models` lists. One model per backend; add a second
  `[backends.<name>]` with `type = "devin"` for another.
- `devin models` marks which ids are free on the user's plan; the rest bill
  the subscription.
- `effort` is refused: effort is part of the model name
  (`swe-2-max` vs `swe-2-max-lightning`), not a flag multi can pass.

## Read-only

devin is not read-only on its own, and the reviewed repo can change its
mind: a `.devin/` in the tree is project config, and project config
outranks our `--config`. multi closes that on three levels. The snapshot
strips `.devin/` from the copy devin reads. The runner forces
`scripts/devin-readonly.json` via `--config`: a deny-by-default permission
set whose deny rules win over a project's allow rules at every level —
measured: a repo config granting write still could not write. Two details
earned empirically (2026-11-16): the read allow must be the scoped
`Read(**)` — a tool-name `read` ignores scoped denies — and `grep` honors
no Read() deny at all, so secret-shaped paths are denied for the read
channel only; a hostile live tree can still grep them out. Snapshots are
unaffected: `snap_is_secret` withholds those files before review. And on a live tree
(`/multi:ask`), where `.devin/` is present, the runner refuses outright on
ANY of `.devin/{hooks*, config*.json, mcp_config*.json}` — the check is on
file names, not content, because `"\u0068ooks"` parses as `"hooks"` for
devin but not for grep (even a harmless-looking permissions-only
config.json loses the benefit of the doubt). `.cognition/` — the same
project dir under its pre-rename name, still read for backward
compatibility — gets the identical scan and the identical snapshot strip.
The answer is a `REFUSED` marker naming the directory. The run itself is `devin -p` under
a clean environment (keys from providers.env do not reach it) with
`--respect-workspace-trust false`, because a trust prompt cannot be
answered in non-interactive mode — and under a fresh per-run HOME that
links only `credentials.toml` (the directory also carries sessions,
plugins and the user's own `mcp_config.json`, none of which may leak in).
The readonly config is a per-run copy: devin rewrites the `--config` file
it is given, appending the caller's org_id and setup state — a personal
id must never land in the repo, and a config "migration" must never
touch the deny lists.

## Training

Verdict `unknown`: Cognition's data-use terms for CLI reviews are not in
the verdict table. If the user knows their plan does not train, set
`trains = false` under `[backends.devin]`.
