# Changelog

## 2.5.0 — 2026-08-26

- Reviewers now work in an explicit review target, not wherever the shell
  happened to be. When the code under review lived in a git worktree other than
  the session's checkout, every backend ran `git` in the wrong directory and saw
  an empty or wrong diff — and the run still produced output, so "two models
  agreed" could mean "two models read nothing." A new `--repo` is threaded
  through probe, collect-context, review-prompt, ask and the code-review skill:
  the target is resolved once and handed to every backend and sub-agent, and the
  resolved path is shown so a wrong-tree review is caught before it runs. The
  path is shell-escaped and output prefixes are forced absolute, so a target
  directory with spaces or shell metacharacters is safe and a backend's `cd`
  cannot drop output inside the reviewed tree. Reviewing the current repo is
  unchanged; this only matters — and now works — when the target is a different
  worktree.
- The five review sub-agents (correctness, security, design, execution, verify)
  are pinned read-only: each now carries an explicit rule never to run a
  tree-mutating git command. Nothing previously stopped a Bash-capable reviewer
  from reverting the user's uncommitted edits while inspecting the tree. This is
  a guard, not a sandbox — real isolation of the reviewer from a hostile tree is
  still tracked as follow-up.
- The context collector no longer leaks a merge commit's SHA into the file list.
  In the clean-merge fallback, `git diff-tree` printed the commit id as its first
  line, which landed in the changed-files list as a phantom 40-character "path";
  `--no-commit-id` drops it.
- `bash scripts/test-injection.sh` is now green on a machine with no global git
  identity (CI, fresh containers). One case merged a branch without passing an
  identity, so the merge died, the harness never assembled, and the empty result
  was reported as an injection leak that had not actually happened. If your CI
  went red here on a clean tree, this is why.
- `run-dir.sh` no longer forces every run outside Claude Code to share one
  `shared` directory: set `MULTI_RUN_ID` to give such a run its own stable id, so
  two concurrent non-Claude-Code runs stop colliding in one place. Inside Claude
  Code nothing changes — the session id is still the identity.
- Marketplace owner name corrected (`szarkan` → `szarkans`).

## 2.4.1 — 2026-08-25

- When the OpenCode reviewer's chosen model dies mid-run, the reviewer retries
  on a fallback model — but the swap used to be silent: the fallback's name sat
  in the report header, and the only trace of the switch was a weak line
  appended to the very bottom, where the eye skates past it. You could read a
  review believing you got the model you asked for. The switch is now announced
  loud, on the first line: `opencode: <asked> produced no answer — fell back to
  <actual>`. If a model quietly degraded to a weaker one, you see it first
  thing, not in a footnote.
- The banner rewrite (and the pre-existing timeout-partial rewrite next to it)
  no longer risk clobbering a valid answer: the `mv` that swaps the rewritten
  file into place now only runs if the write actually succeeded, so a disk error
  mid-rewrite leaves the real answer intact instead of replacing it with a
  truncated file.

- The OpenCode reviewer no longer runs with `--auto`. `opencode run --pure
  --auto` pre-approved every tool call, so the reviewer had full write+exec in
  the live working tree — the comment that called it "read-only" was false
  (measured: a run created a file and ran a shell command). It now runs `--pure
  --agent plan`, which withholds write/edit/bash. A regression guard in
  `test-ask-backend.sh` fails if `--auto` ever comes back or `--agent plan` goes
  missing — the flag whose safety a comment used to assert is now pinned by a
  test that can fail.
  - Known limit, said plainly in the code and tracked as a follow-up: `--agent
    plan` is not a sandbox against a HOSTILE repo. `--pure` skips plugins, not
    the reviewed repo's own `opencode.json` / `.opencode/agent/plan.md`, which
    opencode loads and lets override the plan agent back to write+bash
    (independently verified). The real fix is isolation (issue #12) — reviewing
    a scratch copy with the repo's opencode config stripped. Until then `--agent
    plan` is a strict improvement over `--auto`, not a full fix.
- `check-if-done`: new honesty rule — a diff that only edits tests while the code
  under test stands still is flagged as possibly bending the tests to fit a bug
  instead of fixing the code. Catches "green but faked" completions.

## 2.3.1 — 2026-08-22

- `collect-context.sh` no longer exits 1 on success: the trailing `[ -f ]`
  in the nested-guidance loop leaked its status as the script's. Regression
  assert added to `test-injection.sh`.
- `evals/cases.tsv`: the media-publish ground truth now names the real
  planted bug — the lost `TelegramBadRequest` fallback for preview cards in
  `_send_card` — instead of a publish-status failure that isn't in the diff.

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
