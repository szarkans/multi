# OpenCode — the free floor

What it adds: a third reviewer family at zero cost — OpenCode ships free
models that work without any account or key. Weaker and flakier than paid,
but free redundancy is still redundancy.

## Steps

1. Install, if the probe said MISSING:
   ```
   curl -fsSL https://opencode.ai/install | bash
   ```
   (or `npm install -g opencode-ai`). No signup, no key — free models work
   immediately.

2. That's it for connecting. The model choice is the real conversation:

## Channels

- `opencode/*` — the **free** channel. Works out of the box. Quality warning
  below applies.
- `opencode-go/*` — the **paid** Go subscription channel. If the probe
  printed `opencode-paid-channel: available`, the user already has it — offer
  to spend it deliberately by pinning an `opencode-go/*` model.

When the effective primary model is free (`opencode/*`), say this loudly:

> **You're on free models. They are weaker and less stable — a review may
> come back thin or even empty. Reviewing on free is a real quality
> compromise.** (Fine as a deliberate choice.)

Then offer the research fork from SKILL.md ("sane default" vs "research it
for me" → `model-research.md`).

## The models list

`[backends.opencode]` in `~/.claude/multi/config.toml` (`references/config.md`):

```toml
[backends.opencode]
type = "opencode"
models = ["opencode-go/deepseek-v4-flash", "opencode/deepseek-v4-flash-free"]
```

First model is primary, the rest are fallbacks in order. Preserve everything
else in the file. Remind the user the file is deliberately theirs to hand-edit
later, no agent needed. If it does not exist yet, `$SCRIPTS/setup.sh init`
writes the commented default to start from.

If the probe printed `models-config: LEGACY`, the old `models` file is no
longer read: carry its list into the table above and delete the file.

## How the effective primary is decided (for correct warnings)

First model of the config's list → else (empty list) the probe's auto-pick.
Warn about free **only** based on the effective primary's prefix, not on
whether a config file exists.
