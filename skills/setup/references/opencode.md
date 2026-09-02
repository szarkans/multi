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

## The models config

`~/.claude/multi/models` (override: `MULTI_MODELS_CONFIG`). Hand-editable:
`key: value1 value2 ...` lines, `#` comments, commas also accepted. The only
key today is `opencode:` — first model is primary, the rest are fallbacks in
order:

```
opencode: opencode-go/deepseek-v4-flash opencode/deepseek-v4-flash-free
```

Write space-separated, preserve every other line already in the file. Remind
the user this file is deliberately theirs to hand-edit later, no agent needed.

If the probe printed `models-config: LEGACY PATH`, the file still lives at the
old `~/.config/multi/models` — offer the exact `mv` command the probe showed.

## How the effective primary is decided (for correct warnings)

`MULTI_OPENCODE_MODEL` env if set → else first model on the config's
`opencode:` line → else the probe's auto-pick. Warn about free **only** based
on the effective primary's prefix, not on the config file's existence.
