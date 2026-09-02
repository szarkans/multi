# "Research it for me" — picking current models

The user chose to have you research models instead of keeping defaults. Your
own model knowledge is stale by definition — models ship monthly. **Ground
every claim in a live source**: the CLI's own catalogue and the web.

## For OpenCode

1. Read the live catalogue — both, `--pure` keeps plugin noise out:
   ```
   opencode --pure models
   opencode --pure models --verbose      # includes costs
   ```
2. For names you don't recognize, web-search what they are: quality,
   benchmarks, current standing. Do not guess from the name.
3. Propose **one primary + an ordered fallback chain** (2–4 models), with a
   one-line reason each ("solid coder, free", "paid but stable"). Free
   models flake, so a chain matters more than the perfect single pick.
4. Only after the user approves: write the `opencode:` line to
   `~/.claude/multi/models` (space-separated, preserve other lines — format
   details in `opencode.md`).

## For OpenRouter (or a compatible endpoint)

1. Web-search the current model list and prices — openrouter.ai/models
   sorted by price, or the custom endpoint's own docs.
2. Target the cheap-paid band, **$0.05–0.30 per million tokens**: measured
   here, cheap models find bugs fine, and paid pools don't flap the way
   `:free` pools do. Suggest `:free` only to a user who explicitly won't pay.
3. Propose 2–3 models (first = preferred, rest = fallbacks), each with price
   per million and a one-line reason.
4. After approval, the user sets them (their terminal):
   ```
   $SCRIPTS/setup.sh set MULTI_OPENROUTER_MODELS
   ```
   Remind them of the cost fuse: a low spending limit on the key (the backend
   is agentic — a review costs several times the raw prompt).

## Rules

- Live data beats your memory; when a search contradicts what you "know",
  the search wins.
- Propose, don't impose: the user approves before anything is written.
- No model shopping beyond the ask — pick, write, done.
