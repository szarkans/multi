# Changelog

## 1.9.0 — 2026-09-02

- An OpenCode model that is out of quota no longer eats the whole review budget. Out of quota, `opencode run` writes no events at all and just sits there; the fallback chain then gave every next model a fresh full timeout — measured 44 minutes of a 71-minute review on one silent model, and a 6-model chain could take 4 hours. A healthy run writes its first JSON event within seconds, so a model that has written no event for `MULTI_OPENCODE_STALL` seconds (default 180; a stderr warning does not count) is now killed, with its whole process tree, and the chain moves on; its marker says `SILENT`, not `TIMEOUT` (#16).
- A killed `ask.sh` leaves markers. Terminating it from outside (Ctrl-C, `pkill`, a caller's own timeout) used to leave a 0-byte transcript and neither an answer nor a `.dead`, so a judge reading `*.dead` saw a reviewer that neither answered nor failed. TERM/INT/HUP now stop the children and write `<backend>: KILLED — …` for every backend still running (#23).
- A CLI that cannot write under `$HOME` says so. Run from a sandboxed shell where `$HOME` is read-only, both Codex and OpenCode die on startup and were reported as `NO OUTPUT`, the same text a model that answered nothing gets. The marker now adds that the CLI could not write under HOME and suggests the sandbox. Only the CLI's own stderr lines can trigger it, never text the model read from the reviewed repo. An OpenCode that died at startup without a single JSON event used to be counted as a live "raw capture" answer — that is how today's `RAW CAPTURE ONLY — model=sonnet exit=1` passed as alive — and is now a dead backend with a reason (#21, #22).
- `check-if-done` reviews with OpenRouter and Gemini too. It called `ask.sh` without `--backend`, so it silently got Codex + OpenCode only while `code-review` and `ask` used every configured backend; and its `--model <from probe>` wording sent the agent copying the Claude sub-agent model into OpenCode. It now passes the same explicit backend list as the other skills, and says which probe line to copy (#17, #22).
- Claude reviewer sub-agents cite lines from the file, not from `review.diff`. The agents were pointed at the diff and asked for `FILE:LINE` with nothing saying the diff's numbering is not the file's; one cited line 290 of a 16-line file, and the judge had to renumber by hand, which also broke corroboration against Codex and OpenRouter (#18).
- The ponytail section of the review report is labelled for what it is: the judge's own read under a different ruleset, not a fourth independent reviewer. Its placement between independent sections implied a fourth model family (#19).
- The rule-file skip note is honest about a gitignored `CLAUDE.md`. Untracked ignored files are deliberately counted as touched by the change (a `.gitignore` edit is how a hostile rule file hides), but the note called such a file "modified by the reviewed change" and sent readers hunting for a diff that does not exist. It now says the file is untracked and gitignored; it is still skipped (#20).
- Cleanup: `--fallback` documented as OpenCode-only, a duplicated `local` in the OpenRouter runner dropped, and the `MULTI_RUN_KEEP_DAYS=0` test now checks that an old run survives instead of comparing two literals (#24).

## 1.8.1 — 2026-09-02

- The honest timeout diagnosis now works on macOS too. 2.8.0 located the child's transcript with `find -print -quit`, and `-quit` is a GNU extension that stock macOS `find` does not have — there it failed silently, the transcript came back empty, and every timed-out OpenRouter reviewer was blamed on a rejected key again, which is the exact misdiagnosis 2.8.0 was written to end. It is a plain glob now, with no external command in the path at all.
- The usage example at the top of `ask.sh` still said `--timeout 900` after the default moved to 2400.

## 1.8.0 — 2026-09-02

- A slow reviewer is no longer killed and thrown away: the review budget went from 900s to 2400s. Measured on a real review — the OpenRouter reviewer worked for 36 model turns over 890s and was killed 5 seconds before writing its report, discarding 1.05M paid input tokens and leaving a 0-byte file. `claude -p` prints nothing until it finishes, so any kill costs the whole run.
- A failed OpenRouter reviewer now says what actually happened instead of guessing. It used to claim "the key was probably rejected" every time; now it counts the model turns the child really made and names its transcript, and no branch states a cause as settled — zero turns fits a rejected key, a pool that went 429, or a transcript format this code stopped recognising, and the message says so.
- OpenCode reviews code again: it runs as a plugin-owned read-only agent instead of `--agent plan`, which had been silently refusing its own grep calls and returning an "I'll review…" stub. It also closes the hole where a reviewed repo's own opencode config could re-enable write and bash (#12).
- OpenRouter and Gemini count as real reviewers, so a setup with either satisfies the multi-model gate. The probe stops printing OK for a key it never checked — a dead Gemini key used to show up green.
- Every backend now runs in the directory `--repo` names. OpenRouter and Gemini used to run wherever the caller stood, which meant reviewing a worktree copy could report an empty diff as clean.
- The isolated copy handed to reviewers is stripped of the reviewed repo's `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.claude/` and `.gemini/`, so a hostile repository cannot load its own hooks or instructions into a reviewer. They stay visible inside the diff, where they are inert text a reviewer should see.
- Model pinning moved to `~/.claude/multi/models`, next to everything else this plugin owns. The old `~/.config/multi/models` is still read for one release and setup offers the one-line move.
- A custom endpoint (9router, z.ai, self-hosted) must be `https://` — plain `http://` is refused except on localhost — and setting one says out loud that your API key will be sent there. The endpoint decides where the key goes, so it is as sensitive as the key.
- The probe reports an available paid OpenCode channel even when you already pin your own models. It only did so for users without a config, which excluded exactly the people the offer was written for.
- Reviewers are told the diff is where their reading starts, not where it ends — open the changed files, their tests and their callers before judging.
- `/multi:setup` rewritten, with per-backend reference pages it loads only when needed.
- Russian and Chinese READMEs match the rewritten English one.

## 1.7.0 — 2026-08-28

- Reviewers run on an isolated copy of your work tree, and the Claude reviewer sub-agents lost their shell entirely — a hostile-config opencode or a stray `git checkout -- .` can no longer wipe uncommitted edits, it hits the copy, not your work (#14, real fix; 2.5.0 was prompt-only).
- The copy strips the reviewed repo's `.opencode/`/`opencode.json`, so a hostile plan config can't re-enable opencode's write+bash (#12).
- Secrets stay home: an uncommitted `.env`, key, or `.tfstate` (tracked or not) is withheld from the copy and the diff, so it never reaches the cloud reviewers.
- OpenCode reviews the code again: the diff travels as a `review.diff` file it can read under `--agent plan`, instead of the "I'll review…" stub — until now only Codex actually reviewed.
- `.git`, ignored trees and files over 2 MiB (`MULTI_SNAPSHOT_MAX_FILE_BYTES`) stay out of the copy, so a large repo copies source, not gigabytes.
- Boundary: the copy stops cwd-relative damage (the real #14); it is not an OS sandbox — a reviewer reaching the original by absolute path is out of scope.

## 1.6.0 — 2026-08-28

- OpenCode fallback is now a chain through every free model, not one spare, and
  it advances on a timeout too — not only on an empty answer. A dead free model
  no longer sinks the whole review.
- `~/.config/multi/models` — pin your own OpenCode models by hand (`opencode:
  <primary> <fallbacks…>`), no agent needed. Overrides auto-detection; absent
  file keeps the free default.
- `/multi:setup` now warns loudly when you're on free models and offers to
  research current models, prices and usage for you, then writes your pick.
- Codex gets its own timeout (`MULTI_CODEX_TIMEOUT`, default 600s): high-effort
  runs stop dying at the shared 300s; review runs keep their longer budget.
- OpenCode `error` events are no longer swallowed — a failed run says why it was
  empty instead of "it ran but said nothing".
- Gemini stderr now lands in `.dead.log` on failure instead of vanishing.

## 1.5.0 — 2026-08-26

- `--repo`: reviewers read the right worktree instead of an empty diff when the
  target isn't the session checkout (#13).
- Review sub-agents are read-only — they can't revert your uncommitted work (#14).
- Merge fallback no longer leaks the commit SHA into the changed-files list (#9c).
- `test-injection.sh` passes with no global git identity, so CI stops going red
  on a clean tree (#9a).
- `MULTI_RUN_ID` keeps concurrent non-Claude-Code runs out of one shared dir (#9e-4).
- Marketplace owner name fixed (`szarkan` → `szarkans`).

## 1.4.1 — 2026-08-25

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

## 1.3.1 — 2026-08-22

- `collect-context.sh` no longer exits 1 on success: the trailing `[ -f ]`
  in the nested-guidance loop leaked its status as the script's. Regression
  assert added to `test-injection.sh`.
- `evals/cases.tsv`: the media-publish ground truth now names the real
  planted bug — the lost `TelegramBadRequest` fallback for preview cards in
  `_send_card` — instead of a publish-status failure that isn't in the diff.

## 1.3.0 — 2026-08-22

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

## 1.2.0 — 2026-08-22

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
