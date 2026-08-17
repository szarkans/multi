---
name: ask
description: >-
  Put one question to several models at once — you, OpenAI Codex, and a cheap
  third via OpenCode — and show all the answers side by side. No judging, no
  consensus: three opinions, the user picks. Use for "ask everyone", "what do
  the other models think", "second opinion", "multi ask", or any open question
  where one model's answer is not enough.
allowed-tools: Bash, Read, Grep, Glob
argument-hint: "[the question, in words]"
---

# Ask several models

!`sh -c 'for p in "$CLAUDE_PLUGIN_ROOT/scripts" "$HOME/.claude/skills/multi/scripts" "./.claude/skills/multi/scripts"; do [ -x "$p/probe.sh" ] && { "$p/probe.sh"; echo "scripts-dir: $p"; exit 0; }; done; echo "probe: NOT FOUND — locate scripts/probe.sh in this plugin and run it yourself"'`

One model's answer is one model's priors. Three answers from different families
show you where the question is actually settled and where it only looked
settled.

This is not a review and not a vote. **You do not pick a winner and you do not
merge them into one answer** — that throws away the only thing the user came
for. Show what each said, then say where they differ.

`$SCRIPTS` is whatever the probe printed as `scripts-dir:`.

## Run it

Start the external models first — they take 30–90 seconds and OpenCode spends
most of a minute just waking up. Answer the question yourself while they run.

```bash
$SCRIPTS/ask.sh --question "<the user's question, verbatim>" \
                --out-prefix /tmp/multi-ask \
                --model <from probe> [--fallback <from probe>] [--effort <low|medium|high|xhigh|max>]
```

Pass the question **as the user asked it**. Do not rewrite it into a better
prompt: the point is what different models do with the same words. Add context
they would need and could not see — the file you are both looking at, what was
already ruled out — but leave the question itself alone.

Effort defaults to `medium`. Raise it for a hard design question, drop it to
`low` for something factual.

If neither external model is available, say so and just answer normally. This
skill has nothing to add without them, and pretending otherwise is worse than
a plain answer.

## Report

Your own answer is one of the three, not the frame around the other two. Write
it before you read theirs — otherwise it is not an independent answer.

```
## <one line: what the question was>

**Claude** — <your answer>

**Codex** — <its answer>

**OpenCode (<model>)** — <its answer>   ← or one line saying it did not run

### Where they differ
<the real disagreements, one line each — not a summary of all three>
```

Keep each answer recognisably its own. Trim padding and repetition, but do not
paraphrase a model into agreeing with the others — a disagreement flattened in
the retelling is the one thing this skill exists to prevent.

If all three said the same thing, say that in one line. It is a useful answer:
the question was not as open as it looked.

Then stop. Offer to dig into one of the answers; do not act on any of them
unprompted.
