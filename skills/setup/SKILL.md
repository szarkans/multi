---
name: setup
description: >-
  Walks a non-technical user through connecting every judge model this plugin
  can use — Codex, OpenCode, OpenRouter, Gemini — one at a time, in plain
  words. Use for "multi setup", "set up multi", "configure judges/reviewers/
  backends", "onboarding", or whenever a probe shows missing backends and the
  user needs to know what to do about it.
allowed-tools: Bash, Read, Grep, Glob
argument-hint: "[nothing needed — just run it]"
---

# Connect the judges

!`sh -c 'for p in "$CLAUDE_PLUGIN_ROOT/scripts" "$HOME/.claude/skills/multi/scripts" "./.claude/skills/multi/scripts"; do [ -x "$p/probe.sh" ] && { "$p/probe.sh"; echo "scripts-dir: $p"; exit 0; }; done; echo "probe: NOT FOUND — locate scripts/probe.sh in this plugin and run it yourself"'`

`$SCRIPTS` is whatever the probe printed as `scripts-dir:`. The probe already
ran above — read it, do not run it again.

The user here is not assumed technical. No jargon, no walls of text, one step
at a time, and never make them feel behind for not having done this already.

## What this plugin actually is, in plain words

Say this first, briefly, before touching any config:

This plugin asks several different AI models to look at the same thing
instead of just one. When they agree, that is a real signal. When they
disagree, that disagreement is the whole point — one model alone can't tell
you it might be wrong, three models can.

The lineup:

- **Claude** — already here, always available, nothing to configure.
- **GPT**, through the Codex CLI — needs a ChatGPT account.
- **DeepSeek**, through OpenCode — free, works out of the box once installed.
- **Gemini**, through its own CLI — needs a free API key.
- **OpenRouter** — the bonus one. A single key unlocks many other model
  families at once. Free models by default, or any specific model with
  `--backend name:model` (e.g. `--backend openrouter:z-ai/glm-5.2:free`).

## Fix one thing at a time

Look at the probe output above. For each backend that is missing or not
configured, offer the fix — **one at a time, not all four in a list.** Start
with the most valuable one that's missing. Codex comes first if it's missing:
`/multi:code-review` refuses to run at all without it, the others just get
weaker.

Order to work through, skipping anything already `OK`:

1. **Codex missing or not logged in**
   ```
   codex login
   ```
   Needs a ChatGPT account. This opens a browser to sign in — nothing to type
   here.

2. **OpenCode missing**
   ```
   curl -fsSL https://opencode.ai/install | bash
   ```
   (or `npm install -g opencode-ai` if they'd rather use npm). Nothing to pay
   for or sign up to — it works with free models right out of the box.

3. **OpenRouter not configured**
   Key comes from [openrouter.ai](https://openrouter.ai) — sign up, create a
   key. There's a free tier, no card needed to get one key working. Then they
   run this **themselves, in their own terminal** — it asks for the key and
   does not echo it:
   ```
   $SCRIPTS/setup.sh set OPENROUTER_API_KEY
   ```

4. **Gemini not configured**
   Key is free, from [aistudio.google.com](https://aistudio.google.com). The
   second line is theirs to run in their own terminal, same as above:
   ```
   npm i -g @google/gemini-cli
   $SCRIPTS/setup.sh set GEMINI_API_KEY
   ```

Give one fix, wait for them to do it or ask a question, then move to the
next. Do not paste all four blocks in one message — that's the thing this
skill exists to avoid.

## Never ask for a key in chat, and never run the command yourself

Not a preference — a key that reaches this conversation is a leaked key: it is
in the transcript, and if it also reached a command line it is in their shell
history and was visible in `ps` to everyone on the machine. So `setup.sh set
<NAME>` is given **without** a value and run **by them**, in their own
terminal: it prompts, reads the key without echoing it, and writes it out of
sight. If a key does land in the chat anyway, say plainly that it should be
rotated at the provider — a leaked key is not un-leaked by deleting a message.

Keys live outside this plugin's folder, in `~/.claude/multi/providers.env`,
which `scripts/setup.sh` sets to permission `600` — only their own user can
read it. On Windows/MSYS and on some mounts (exFAT, some NTFS) `chmod` is
accepted and does nothing; the script checks afterwards and prints a warning
when that happened, so if you see no warning the file really is owner-only,
and if you see one, repeat it to them rather than restating the `600` line.

## Finish: show where things stand

Run:
```
$SCRIPTS/setup.sh status
```

Report it as one short block — who's connected, and what each missing one
would still add:

```
Connected: Claude, Codex
Not yet:   OpenCode (free third opinion), OpenRouter (bonus — many models via one key), Gemini (free fourth opinion)

With just Claude: /multi:code-review refuses to run (needs Codex at minimum).
/multi:ask and /multi:adhd still work, just with fewer opinions.
```

Be honest about degradation, not alarming about it. Missing backends are a
normal starting state, not a broken install.

Then stop. Don't chain into another skill or start reviewing anything —
this skill's only job is getting the judges connected.
