# Changelog

## 1.14.0 — 2026-09-12

- `claude-headless` backends (OpenRouter, DeepSeek) are killed for silence, not by the clock: `stall` seconds (default 600) without the transcript growing → `STALLED`, `timeout` is now a ceiling (default 1800). Why: a flat 300s cut a model 38 paid turns into an `/ask` and threw its work away.

## 1.13.1 — 2026-09-11

- The `a|b` profile alternatives from 1.13.0 are gone, hours after they shipped. `["codex", "glm", "deepseek|glm"]` in DeepSeek's peak hours ran GLM twice and paid for both; deduplicating alternatives against the rest of the profile was ten more lines on a mechanism nobody had asked for. A backend with `avoid` simply sits out its windows: the user put them there, the answer file and the report say which hour it is sitting out and when it is back, and a profile that wants a reviewer in those hours lists one. `--ignore-avoid` stays. `resolve` is back to ten columns.

## 1.13.0 — 2026-09-10

- A backend can sit out hours: `avoid = ["Mon-Fri 01:00-04:00 UTC", "Mon-Fri 06:00-10:00 UTC"]` under any `[backends.<name>]`. Written for DeepSeek, which bills every token double in those windows (its published peak hours as of 2026-09-10; it moved them on 2026-08-16, which is why the windows live in the user's config and not in the plugin), and generic on purpose: any backend, any list of windows, a day range or none, a window that wraps midnight. UTC only — the word is required and nothing else is accepted, so nobody has to guess whose zone a config was written in. Decided once when the run starts: a review that begins at 09:50 finishes. Inside a window the backend is not launched, and its answer file says `deepseek: sits out Mon-Fri 06:00-10:00 UTC (avoid, in config.toml) — now Wed 08:12 UTC, back at Wed 10:00 UTC`, so the report names it as sat out rather than losing it; `setup.sh status` and `probe.sh` print `CLOSED NOW` with the same sentence. `config.py resolve` and `backends` carry the verdict as a new last column (`ask.sh`, `setup.sh` and `probe.sh` read it; `MULTI_NOW=<epoch>` in the environment evaluates the windows at a fixed instant for tests).
- A profile entry can be alternatives: `"deepseek|glm"` runs the first one whose backend is not sitting out a window, under its own name, and the answer ends with `[multi] deepseek sits out … ; glm ran in its place` — a peak-hour review swaps a reviewer instead of losing one. `|` splits before the `:` pin, so `deepseek|openrouter:z-ai/glm-5.2:free` pins the model to openrouter. When every alternative is closed the first is the participant and its reason names the rest. `resolve` carries this as an eleventh column, `swapped`. *(Removed in 1.13.1.)*
- `ask.sh --ignore-avoid` runs every backend as if it had no windows, this run only — the user's "forget peak hours, run it". The ask, code-review and check-if-done skills pass it only on that explicit word; the config is never edited for one run.
- DeepSeek as a backend is a config section, no code: `type = "claude-headless"`, `base_url = "https://api.deepseek.com/anthropic"`, `models = ["deepseek-flash"]` (V4.1 Flash; released 2026-09-10), key `DEEPSEEK_API_KEY`. Example in `config.example.toml`, `providers.example.env` and the setup skill's config reference. The endpoint is DeepSeek's documented Anthropic-compatible one; it was not exercised live in this release — no key on the machine that built it.

## 1.12.0 — 2026-09-08

- The judge lists everything before it judges. The review report opens with `## 📋 Everything raised (N)`: every finding from every reviewer, numbered, with its author, its `file:line` and its claim in the reviewer's words, and the buckets below cite those numbers. Two findings merge only when they name the same mechanism; the same line with a different mechanism stays two, and a dropped finding keeps its own text and a reason that cites the line contradicting *it*. Measured on 8 real bugs (commit that introduced the bug, headless, same reviewers): the old judge delivered 3 of 8 while its own reviewers had found 5 — Codex's real finding at one line was folded into a sub-agent's speculation at a neighbouring line and dropped with it, and a bug three reviewers agreed on was merged into a broader neighbour and lost its mechanism. With the inventory the report delivers what the reviewers found, 6 of 8, at the same cost per review; the one finding still lost is a compound sentence from Codex whose second half is the bug, and the rule now says a two-mechanism sentence is two lines — that clarification is checked on the judge step alone, not end-to-end. Swapping the judge model did not fix it: Opus on the same inputs lost the same finding two times out of three, by the same merge.
- Control arm against the built-in `/code-review high`, same bugs, same judge model: its report found 3 of 8. Scoreboard and protocol in `evals/RESULTS.md`; the harness is `evals/run-arms.sh` and `evals/grade-arms.sh` (blind grading: reports flattened to `file:line | claim`, three votes, majority). The comparison is one run per arm on eight bugs — a one-bug difference is noise; the reviewers' 5-vs-3 and the report's 6-vs-3 are the gaps that clear it.
- `evals/run.sh` and `run-arms.sh` accept a seventh `severity` column in the case file.

## 1.11.1 — 2026-09-07

- A pool passed over is named. `claude-headless` backends probe each model in the list with one token and run on the first that answers; the answer's trailer now says which ones were skipped and what they said — `[multi] openrouter pools skipped before it: qwen/qwen3.8-flash (RATE LIMITED (HTTP 429))` — and `setup.sh status` prints the same after `will use`. The review used to run on the second model with nothing saying the first was busy, which read as "the config order is wrong" (measured 2026-09-07: qwen first in the list, GLM ran). `ALL POOLS BUSY` carries the per-pool codes too.

## 1.11.0 — 2026-09-07

- A run no longer starts on top of one that is still going. `ask.sh` clears every answer file before launching, and a `claude`/`codex` from an earlier run on the same `--out-prefix` then finished into a deleted inode: its runner found an empty path and marked it `NO OUTPUT` with exit 0 while the transcript held a full review. Measured 2026-09-07: four branches reviewed in one session, all on `$RUN/review`, and three sets of GLM and OpenRouter answers went that way — that is what "OpenRouter and GLM don't work" was. `ask.sh` now takes a lock (bash's own `noclobber` open — not `mkdir`: the uutils coreutils that Ubuntu 25.10+ ships answer 0 to both of two racing `mkdir`s, measured 17 of 30 races on tmpfs), reads the previous run's roster, and refuses the prefix while any of its markers belongs to a live process, saying what to do instead; a marker whose pid is gone is a leftover, not a block. Markers are written whole and renamed into place, so a reader never sees a half-written one as "nobody here".
- `<answer>.running` says who and since when: `<pid of the backend's runner> <start epoch> <timeout>`, so an `ls` beside an empty answer shows three minutes in from thirty. The pid is the backend's own subshell, not `ask.sh`'s: it outlives a SIGKILLed `ask.sh` and keeps writing, and liveness has to mean that process. It used to be an empty file (#27).
- `<prefix>.run` is the roster of a run: one line per participant, written before anything launches, then `<backend> <seconds>` as each one ends — so a reader that arrives mid-launch sees the whole run, and the durations say which backend was the slow one. `scripts/wait.sh --prefix <prefix> [--max N]` reads it, blocks until every backend has ended, and prints one line per backend — `codex 5m12s ok`, `glm 23m04s ok`, `openrouter 40m00s FAILED: <the .dead text>`, or `still running (timeout 2400s)` when `--max` ran out first (exit 1: call again; a Bash tool call is capped at ten minutes). A marker nobody owns beside an answer means the runner was killed and the answer is partial, and it says so. Status is read from the roster and markers only, never from answer text and never from a glob (`review-*` would also match a `review-2` beside it). The review and check-if-done skills wait through it, say outright that an empty answer beside a live `.running` is a reviewer still writing, and say that `ask.sh` runs as a background task — GLM answered after 23 minutes with the one finding nobody else had, and had been written off at nine (#27).
- A runner that ends with nothing written and no marker is marked `NO OUTPUT` in its own subshell, the moment it ends; the parent used to do it only after every backend was done, so a reader in between saw a finished backend with no answer and no reason.
- `snapshot.sh --paths "<paths>"`: every path named must be in the final copy, or the snapshot fails (exit 2, no path on stdout, so the skill's "snapshot failed — not reviewing" guard fires) and says why — `docs/item-map is not in the copy: ignored via .git/info/exclude:40`, from `git check-ignore -v` (the source and line only; the pattern is text from the reviewed repo). The copy takes `git ls-files --exclude-standard`, which honours `.git/info/exclude`, so a `docs/` line there silently dropped the folder under review and Codex, OpenRouter and three sub-agents all agreed there was nothing to review. The check runs after the config purge, against the tree the reviewers get; a harness rule file (`CLAUDE.md`, `AGENTS.md`, `.mcp.json`, …) is stripped from the copy on purpose and is noted, not failed — its change is in `review.diff`; a path the diff deletes or renames is not missing either; a glob is not checked and says so; a path that does not exist at all fails the same way. The review skill passes `--paths` whenever the target is paths (#29).
- The skill headers work in a git worktree session. Claude Code gates every shell command there statically and refuses `sh -c`, `bash <file>`, `${VAR:-default}`, `for` loops and `$PWD` arguments (measured 2026-09-07 with `claude -w`); the probe header was a `sh -c` loop, so `/multi:code-review` died on line one with `Shell substitution failed`, reading as a broken plugin. It is now a `||` chain of plain paths — `"$CLAUDE_PLUGIN_ROOT/scripts/probe.sh" || "$HOME/.claude/skills/multi/scripts/probe.sh" || ./.claude/skills/multi/scripts/probe.sh` — which the gate lets through; `probe.sh` prints `scripts-dir:` itself. Every skill names the failure and the one-command workaround for the case the gate changes again (#26).
- `setup.sh status` times the one-token check of the model that answered and prints it (`OK — will use x (1s to answer one token right now)`); five seconds or more adds `SLOW — expect a review here to take tens of minutes; a bad choice for the default profile`. One token in seconds is eighty review turns in minutes; nothing measured that before a run. It is one sample at one moment, and says so (#28).
- The `isn't described by this version's model catalog … auto-compact keeps this session within 200k tokens` paragraph is now named in the `TIMEOUT` / `NO OUTPUT` marker for what it is: Claude Code's context-window notice for a model name it does not know, printed on every run on a non-Anthropic endpoint, not the cause. It was the only thing in the stderr log of a run that died silently, and read as the reason (#28).
- `config.example.toml`: OpenRouter's free/flash pools are out of the everyday profile (`normal = ["codex", "glm"]`) — measured 2026-09-06, 25–40 minutes for one review on `qwen3.8-flash` via OpenRouter while the same model on a direct key took 5. They belong in a profile picked on purpose, and the `free` profile pins `openrouter:z-ai/glm-5.2:free` rather than the bare backend, whose chain tries paid models first (#28). Not done from #28: a timeout derived from a measured speed — the pools' speed changes by the hour, and a measured 5-minute pool killing a 20-minute review would hide answers the current fixed budget keeps.
- Known limit, left as is: liveness is `kill -0` on the pid in the marker. A pid recycled by an unrelated long-lived process after a SIGKILL would hold the prefix until that process exits; the fix is `--out-prefix` something else. No portable way to tell a recycled pid from the real one was worth its size.

## 1.10.0 — 2026-09-04

- One config file: `~/.claude/multi/config.toml`. Backends, their models, endpoints, per-backend timeouts and named profiles all live there, with comments; `providers.env` keeps only keys. Read by `scripts/config.py` (stdlib `tomllib`, with a vendored `tomli` for python < 3.11). No file means the built-in default — codex, opencode, openrouter — and `setup.sh init` writes it out to edit.
  - Any number of Anthropic-compatible endpoints, each its own backend: `[backends.zcode]` with `type = "claude-headless"`, its own `base_url`, `models` and key variable, next to `openrouter` instead of replacing it. Before, one endpoint could be pointed away from OpenRouter and that was all.
  - Profiles: `[profiles] normal = ["openrouter:x-ai/grok-4.5", "zcode", "codex"]`, picked with `ask.sh --backend normal`; no `--backend` runs `default_profile`. `code-review`, `check-if-done` and `ask` stop hard-coding a backend list, so the config actually decides who reviews — a knob the skills bypass changes nothing. `adhd` keeps its fixed two external frames on purpose: its frames are distinct engines, not a reviewer roster.
  - `backend:model` pins exactly that model with no fallback. Asking for a paid model and silently getting a free one is worse than a marker saying it failed.
  - Per-backend `timeout`; `ask.sh --timeout N` is a floor (every backend gets at least N, the review skill passes 2400), never a cut — the same rule codex already had with its 600s.
  - A broken config stops every run before anything launches, naming the file and the key: unknown type, unknown key, a profile naming a backend that does not exist or sharing a backend's name, a `claude-headless` without `models` or `base_url`, a non-`https` endpoint (plain `http` only when the parsed host is the loopback), a model name with whitespace, a key variable or backend name that is not a plain identifier, more than one model on `codex` or `gemini` — those two do not walk a chain yet, and the config says so instead of ignoring the rest.
- Removed, not aliased: the `models` file, `MULTI_OPENROUTER_MODEL`, `MULTI_OPENROUTER_MODELS`, `MULTI_OPENROUTER_FALLBACKS`, `MULTI_OPENROUTER_BASE_URL`, `MULTI_OPENCODE_MODEL`, `MULTI_GEMINI_MODEL`, `MULTI_BACKEND_TIMEOUT`, `MULTI_CODEX_TIMEOUT`, `MULTI_OPENCODE_STALL`, and the `--or-model` / `--gemini-model` flags (`name:model` does it, and a by-type flag picks the wrong backend once two share a type). Reading the old variables "just in case" would be a third config. While `providers.env` still sets any of them nothing runs: the old `MULTI_OPENROUTER_BASE_URL` chose where the key goes, and a config that ignored it would send a z.ai key to openrouter.ai. `setup.sh init` still works in that state, the probe says `models-config: LEGACY` while the old file exists, and `setup.sh set MULTI_*` explains where the value went. `setup.sh set` accepts exactly the key variables the config's backends read.
  - Upgrading: move `MULTI_OPENROUTER_*` values into `[backends.openrouter]` (`base_url`, `models`) and the `models` file's list into `[backends.opencode]`; timeouts become `timeout = N` per backend. Keys need no change.
- `config.example.toml` and `providers.example.env` in the repo show every backend type, every field, a second endpoint with its own key, and several profiles; a test keeps the example valid.
- `python3` is now required to run anything: bash cannot read TOML. It was already needed to read OpenCode answers.

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
