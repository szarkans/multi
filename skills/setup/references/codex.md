# Codex — GPT as a reviewer

What it adds: OpenAI's frontier model as a second reviewer family, and the
adversarial second pass in `/multi:code-review` ultra mode. If the user has a
ChatGPT subscription, this costs nothing extra — the CLI spends that
subscription's quota, not API credits.

## Steps

1. Install, if the probe said MISSING:
   ```
   npm install -g @openai/codex
   ```
   (Homebrew users: `brew install codex`.)

2. Log in, if the probe said NOT LOGGED IN:
   ```
   codex login
   ```
   Opens a browser to sign into their ChatGPT account — nothing to type or
   paste. Plus/Pro/Team all work; there is no separate "API key" step.

3. Verify: `codex login status` should say logged in. The next probe will
   show `codex: OK`.

## Notes

- No ChatGPT account and not willing to make one → skip Codex entirely; an
  OpenRouter-style key covers the "second family" role instead. Don't push.
- The plugin runs codex read-only (`-s read-only`) and with the reviewed
  repo's AGENTS.md disabled — nothing to configure for that, it's built in.
