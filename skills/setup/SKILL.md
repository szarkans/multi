---
name: setup
description: >-
  Walks a user through connecting the judge models this plugin can use — Codex,
  OpenCode, OpenRouter (or any compatible endpoint: 9router, z.ai, Moonshot),
  Gemini — and through picking models, including "research current models for
  me". Use for "multi setup", "set up multi", "configure judges/reviewers/
  backends", "connect 9router", "change/pick models", "onboarding", or whenever
  a probe shows missing backends and the user needs to know what to do about it.
allowed-tools: Bash, Read, Grep, Glob, WebSearch, WebFetch
argument-hint: "[nothing needed — just run it]"
---

# Connect the judges

!`sh -c 'for p in "$CLAUDE_PLUGIN_ROOT/scripts" "$HOME/.claude/skills/multi/scripts" "./.claude/skills/multi/scripts"; do [ -x "$p/probe.sh" ] && { "$p/probe.sh"; echo "scripts-dir: $p"; exit 0; }; done; echo "probe: NOT FOUND — locate scripts/probe.sh in this plugin and run it yourself"'`

`$SCRIPTS` is whatever the probe printed as `scripts-dir:`. The probe already
ran above — read it, do not run it again. It detected everything detectable:
which CLIs are installed, who is logged in, which keys exist, whether the
OpenCode paid channel is available, and what other AI CLIs live on this
machine. **Never ask the user about anything the probe already answered.**

The user here is not assumed technical. No jargon, no walls of text, one step
at a time, and never make them feel behind for not having done this already.

## First contact: what this is, in three sentences

Only when little or nothing is connected yet (Claude alone, or one backend).
Returning users with a working lineup skip straight to fixing gaps.

> This plugin asks several different AI models to look at the same thing
> instead of just one — when they agree it's a real signal, and when they
> disagree, that disagreement is exactly what one model alone can never show
> you. You'll use it mostly as `/multi:code-review` (several models review
> your changes before a PR), `/multi:ask` (one question, several independent
> answers), and `/multi:check-if-done` (is this actually finished?).
> Claude is already connected; each backend below adds an independent
> reviewer, most at no extra cost.

## One question, only about what the probe can't see

The probe knows what's installed. It cannot know what accounts the user has
or what they're willing to pay. Ask **one** question covering only the
missing backends, shaped like this (adjust to the actual gaps):

> To pick what to connect, tell me:
> - Do you have a ChatGPT subscription? (unlocks GPT as a reviewer, no extra cost)
> - Are you okay creating one free account + API key? (unlocks many model
>   families at once via OpenRouter or a compatible service)
> - Or keep it strictly free-and-local for now? (OpenCode's free models)

Then recommend an order — the fewest steps to reach **at least one non-Claude
reviewer** (without one, `/multi:code-review` refuses to run; with one it
works, and each further backend makes it stronger). Typical value order:
Codex if they have the subscription, otherwise an OpenRouter-style key,
OpenCode as the free floor, Gemini as a free extra.

## Connect each chosen backend

Work through the user's picks **one at a time** — give one step, wait for
them to do it, then the next. Never paste four install blocks in one message.

For each backend, read its reference file first and follow it:

- **Codex (GPT)** — `references/codex.md`
- **OpenCode** — `references/opencode.md`
- **OpenRouter / 9router / z.ai / any compatible endpoint** — `references/openrouter.md`
- **Gemini** — `references/gemini.md`

If the probe printed a `models-config: LEGACY PATH` line, offer the one-line
`mv` it shows — everything of this plugin lives under `~/.claude/multi/`.

If the probe listed `other-ai-clis`, you may mention them in one sentence as
detected-but-not-yet-supported. Do not improvise support for them.

## Picking models

When a backend is connected but the model choice is the question (free vs
paid, which pin, which fallbacks) — or the user asks "which models should I
use" — offer the fork:

1. **Sane default** — keep what the probe picked; say in one line what that
   is and what it costs (usually: free, weaker, can flake).
2. **"Research it for me"** — read `references/model-research.md` and follow
   it: live catalogue + web search (your own model knowledge is stale),
   propose a pick, write the config only after the user approves.

## Keys never touch this chat

Not a preference — a key that reaches this conversation is a leaked key: it
is in the transcript, and if it also reached a command line it is in shell
history and was visible in `ps`. So `setup.sh set <NAME>` is given **without**
a value and run **by the user, in their own terminal**: it prompts, reads the
key without echoing, and writes it out of sight. If a key lands in the chat
anyway, say plainly it should be rotated at the provider — deleting a message
does not un-leak it.

Keys live in `~/.claude/multi/providers.env`, permission `600` (owner-only).
On Windows/MSYS and some mounts `chmod` silently does nothing; `setup.sh`
checks afterwards and warns when that happened — if it warned, repeat the
warning to the user instead of claiming the file is protected.

## Finish: show where things stand

Run:
```
$SCRIPTS/setup.sh status
```

This one actually verifies keys over the network (the probe above does not).
Report one short block — who's connected, and what each missing one would add:

```
Connected: Claude, Codex, OpenRouter (endpoint: 9router)
Not yet:   OpenCode (free extra reviewer), Gemini (free extra reviewer)

/multi:code-review works — you have non-Claude reviewers. Each missing
backend is one more independent opinion, most at no extra cost.
```

Be honest about degradation, not alarming: missing backends are a normal
starting state, not a broken install. Then stop — this skill's only job is
getting the judges connected, not running a review.
