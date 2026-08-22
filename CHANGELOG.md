# Changelog

## 2.3.0 — 2026-08-22

The second transport core is gone. `review-codex.sh` and `review-opencode.sh`
(353 lines, two near-duplicate prompt builders each running its own backend)
are replaced by `review-prompt.sh` — prompt assembly only — with execution
routed through the one transport, `ask.sh`. Measured before and after on the
eval corpus: recall unchanged (5/5).

- `codex exec review` is not used anymore: measured equal to plain
  `codex exec` with the same prompt, and its own system prompt was overriding
  ours. Codex now always runs `exec -s read-only`.
- `ask.sh` learned `--timeout <seconds>` (reviews get 900s instead of the
  300s question budget) and now guards partial answers: a timed-out backend
  that already produced output keeps it, marked as partial, instead of being
  overwritten by a bare TIMEOUT line.
- The legacy raw-capture fallback keeps its anti-spoofing armor: bounded to
  80 lines, ANSI-stripped, every line prefixed `raw| ` so untrusted output
  can never masquerade as a finding. Caught by the multi-model review of this
  very refactor (three model families agreed), covered by restored tests.
- `evals/run.sh`: a relative `--out` no longer breaks the worktree revert
  (cases used to silently run on an empty diff).
- Test suites rewired to the new pair; every injection and failure-path
  assertion preserved.

## 2.2.0 — 2026-08-22

Two ways a failed reviewer could lie about its status are fixed, and the
core contract is now written down.

- Context truncation no longer cuts UTF-8 mid-character — a strict reviewer
  died on the broken prompt and the failure read as "backend unavailable"
  (#6, thanks @jojoprison). Regression test: `test-context-utf8.sh`.
- A failed backend now explains itself: the `.dead` marker carries a one-line
  reason (`codex: TIMEOUT after 900s`); the raw diagnostics tail goes to
  `.dead.log`, kept separate and treated as untrusted. Previously the reason
  was lost and the reviewer was reported as absent (#7).
- Injection through the status channel is closed and covered by tests:
  backend stderr can never reach the trusted marker (`test-injection.sh`,
  `test-reviewer-failures.sh`).
- README: the single-core contract — `ask.sh` is the only transport, a skill
  owns nothing but its prompt and report format — plus a 15-line new-skill
  template.
