# Gemini — a free extra reviewer

What it adds: Google's model family as one more independent opinion. The key
is free, with a daily quota — enough for regular reviews.

## Steps

1. Install the CLI, if the probe said MISSING:
   ```
   npm i -g @google/gemini-cli
   ```
2. Get a free key at [aistudio.google.com](https://aistudio.google.com)
   (Google account → "Get API key").
3. The user runs this **themselves, in their own terminal** (prompts for the
   key, never echoes it — never ask for the key in chat):
   ```
   $SCRIPTS/setup.sh set GEMINI_API_KEY
   ```
4. Verify with `$SCRIPTS/setup.sh status`.

## Notes

- Model choice is optional: empty means the CLI's default, or pin with
  `$SCRIPTS/setup.sh set MULTI_GEMINI_MODEL`.
- Honest caveat if asked why Gemini is "extra": its CLI offers no way to stop
  reading instruction files from the reviewed tree, so the plugin strips
  those files from review copies instead — built in, nothing to configure.
