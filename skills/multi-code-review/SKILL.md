---
name: multi-code-review
description: >-
  Run a code review with independent models — Claude's built-in /code-review,
  OpenAI Codex, and (optionally, when installed) Google Antigravity — in
  parallel, then reconcile their findings into one consensus report. Use
  whenever the user wants a second model's eyes on a diff, a cross-model or
  "double"/"triple" review, a higher-confidence review before opening a PR or
  merging, or explicitly mentions "multi-code-review", "codex review",
  "have Codex and Claude both review", "consensus review", "antigravity
  review", or "cross-check my changes with codex". Prefer this over plain
  /code-review whenever the user asks for Codex or Antigravity involvement or
  a second opinion, even if they don't say the exact skill name.
---

# Multi Code Review

Independent reviewers catch more than one, and the ones they *agree* on are
the ones worth acting on first. This skill runs Claude's `/code-review`,
OpenAI Codex, and — when available — Google Antigravity CLI against the
**same diff at the same time**, then merges their findings: issues several
models flagged rise to the top, issues only one flagged get a quick
verification pass before they reach the user, and false positives get
filtered out.

By default it is **report-only** — one pass, no edits, no PR comments; the user
decides what to do with the report. There's an opt-in **loop mode** (last section)
that instead fixes and re-reviews until the reviewers go quiet — reach for it only
when the user explicitly asks to "loop" / "keep going until it's clean".

## Prerequisites & reviewer state

The skill remembers which reviewers are known-good in a small state file, so it
does **not** re-probe them on every run:

```
~/.config/multi-code-review/state.json
→ {"codex": "ok", "antigravity": "ok" | "skipped"}
```

Read it first (`cat`, missing file = first run), then:

1. **Git repo with reviewable changes.** If `git status` is clean and no
   base/commit is given, there's nothing to review — say so and stop.

2. **Codex — mandatory.**
   - State says `"codex": "ok"` → trust it, skip the probe.
   - Otherwise probe: `command -v codex` and `codex login status` (must say
     "Logged in"). Success → write `"codex": "ok"` to the state file.
   - Missing or not logged in → **abort the whole skill.** Without Codex there
     is no second model and the skill loses its point. Tell the user plainly:
     install and log in (`npm install -g @openai/codex`, then `codex login`),
     or just use plain `/code-review`. Never fall back to a silent
     single-model review.
   - If a later `codex exec` fails with an auth error, clear the `codex` flag
     from state so the next run re-probes.

3. **Antigravity — optional third reviewer.**
   - State says `"antigravity": "ok"` → include it as the third reviewer.
   - State says `"antigravity": "skipped"` → run Claude + Codex only. Don't
     probe, don't mention Antigravity again. Re-probe ONLY when the user
     explicitly asks ("with antigravity", "enable antigravity", "re-check
     antigravity") — then update state with the fresh result.
   - No `antigravity` key (first run): probe `command -v agy` and
     `agy --version` (needs **≥ 1.0.15**; `agy` is the official Google
     Antigravity CLI — not a plugin, not Gemini CLI, not the SDK). Works →
     write `"antigravity": "ok"`, three reviewers. Missing, too old, or
     erroring → tell the user **once**, in one line, that installing Google
     Antigravity CLI would add Gemini as a third reviewer (entirely
     optional), write `"antigravity": "skipped"`, and continue with two.
   - The user saying "without antigravity" for this run → skip it this run,
     leave the state file alone.

## Step 1 — Settle effort and scope

**Effort** comes from the user (they said "high", "max", etc.). If unspecified,
default to `high` and mention it. This drives the reviewers so they work at a
comparable depth.

- Codex effort is always `xhigh`, regardless of the requested effort.
- Antigravity always runs `Gemini 3.1 Pro (High)` — its model string is fixed.

`ultra` is a heavy async cloud review — it doesn't fit a synchronous consensus.
If asked for ultra, suggest `max` instead, or run `/code-review ultra` on its own.

**Scope** — always ask the user (unless they already told you), because "my
changes" is ambiguous and all reviewers must look at the *same* range:

- **Uncommitted** — staged + unstaged + untracked. This is the default and the
  cleanest case: reviewers align on the working tree with no extra work.
- **Branch vs base** — the whole branch against `main`/`master`. Compute
  `BASE=$(git merge-base <main> HEAD)`.
- **Single commit** — one commit's changes (`git show <sha>`).

Translate the chosen scope into (a) a phrase for the Codex/Antigravity prompts
and (b) an arg/note for `/code-review` (see below).

## Step 2 — Launch reviewers in parallel

The value of "at the same time" is real wall-clock savings: Codex at xhigh and
Antigravity can each take minutes. Start both in the **background** first, then
do the Claude review while they churn.

**2a. Kick off Codex (background).** Fill the scope line, pick an output path,
and run with `run_in_background: true`:

```bash
codex exec -o "$OUT" -s read-only -c model_reasoning_effort="xhigh" \
"You are a senior code reviewer. <SCOPE LINE>

Report ONLY real, high-impact problems on the CHANGED lines: genuine bugs,
security holes, data-loss risks, or violations of this repo's CLAUDE.md.
Ignore, as false positives: pre-existing issues, problems on lines the change
didn't touch, pure style/nitpicks, missing tests, and anything a linter or type
checker would catch. Don't run the build.

Output one line per finding, nothing else:
FILE:LINE | SEVERITY(High/Med/Low) | one-sentence reason
If there are no real issues, output exactly: No issues found."
```

`<SCOPE LINE>` is one of:
- Uncommitted → `Review ONLY the uncommitted changes — use git status and git diff to find staged, unstaged, and untracked changes.`
- Branch → `Review ONLY the changes on this branch versus the base — run: git diff $BASE...HEAD`
- Commit → `Review ONLY the changes introduced by commit <SHA> — run: git show <SHA>`

`-o "$OUT"` writes just Codex's **final message** to `$OUT` (the findings list).
Don't parse the noisy live stream — read `$OUT` after it finishes. `-s read-only`
keeps Codex from touching the tree.

**2b. Kick off Antigravity (background, only if active).** Antigravity has no
reliable read-only mode — `--sandbox` limits shell commands but doesn't
guarantee file-write tools are blocked — so it must NEVER run in the real
repo. Give it a disposable detached worktree:

```bash
TMP_ROOT="$(mktemp -d)"; TMP_REPO="$TMP_ROOT/repo"
git worktree add --detach "$TMP_REPO" HEAD

# Uncommitted scope only: carry the working-tree state into the copy
git diff HEAD --binary > "$TMP_ROOT/changes.patch"
[ -s "$TMP_ROOT/changes.patch" ] && git -C "$TMP_REPO" apply "$TMP_ROOT/changes.patch"
git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
  mkdir -p "$TMP_REPO/$(dirname "$f")" && cp -a "$f" "$TMP_REPO/$f"
done
```

For branch scope the worktree at `HEAD` is already right (it reviews
`git diff $BASE...HEAD`); for commit scope check out that commit's state.

Then launch (background, `cwd="$TMP_REPO"`), keeping stdout and stderr apart:

```bash
cd "$TMP_REPO" && timeout 10m agy \
  --model "Gemini 3.1 Pro (High)" \
  --sandbox \
  --print-timeout 8m \
  --print "$PROMPT" \
  < /dev/null > "$AGY_OUT" 2> "$AGY_ERR"
```

`$PROMPT` (fill `<SCOPE>` with the same scope text as Codex's):

```text
You are an independent senior code reviewer.

<SCOPE>

Review only the changes in the specified scope.

Report only genuine, high-impact problems introduced by changed lines:
- functional bugs;
- security vulnerabilities;
- data-loss risks;
- race conditions;
- broken edge cases;
- violations of repository instructions such as CLAUDE.md.

Do not modify, create, delete, rename, or format any files.
Do not fix the findings.
Do not run builds or test suites.
Ignore pre-existing problems and unchanged lines.
Ignore style issues, nitpicks, missing tests, documentation issues, and anything
that a normal linter, formatter, or type checker would catch.

Output exactly one finding per line:

FILE:LINE | SEVERITY(High/Med/Low) | one-sentence reason

Output nothing except findings.

If there are no real issues, output exactly:

No issues found.
```

Never pass `--dangerously-skip-permissions`. Always clean the worktree up
afterwards — on success, timeout, and every failure path:

```bash
git worktree remove --force "$TMP_REPO" 2>/dev/null || true
rm -rf "$TMP_ROOT"
```

The cleanup must never touch the main working tree.

**2c. Run the Claude side.** While the background reviewers run, invoke the
built-in review via the Skill tool: `code-review` with the mapped effort. Do
**not** pass `--comment` or `--fix` — we only want its findings back, not side
effects.

- For **uncommitted** scope, `/code-review` reviews the working tree directly —
  aligned by default.
- For **branch/commit** scope, tell it the range explicitly. If it can't target
  that range, dispatch one `general-purpose` subagent instead with the same
  criteria as the Codex prompt above, scoped to `git diff $BASE...HEAD` (or
  `git show <sha>`), and use its findings as the Claude side. Alignment of the
  reviewers on the same diff matters more than which mechanism produced it.

## Step 3 — Collect, then merge

When the background tasks signal done, read `$OUT` (Codex) and `$AGY_OUT`
(Antigravity). Codex empty or errored (e.g. auth failure) → treat as "no
result", note it, and clear the state flag if it was an auth error — don't
stall.

Antigravity counts as **successful only when all three hold**: exit code `0`,
non-empty stdout, and stdout is either `No issues found.` or well-formed
finding lines. Empty stdout is *absence of a result*, not absence of problems.
Timeout, auth error, unknown model, empty stdout, crash → report it as
`Antigravity unavailable: <short reason>` and continue with the others.

Normalize every finding to `{reviewer, file, line, severity, summary}`.
Match findings across reviewers by same file + overlapping/adjacent lines +
same underlying issue — never by wording (the models describe things
differently). Then bucket:

- **Unanimous consensus** — flagged by all three (only exists in 3-reviewer
  runs). Highest confidence.
- **Majority consensus** — flagged by exactly two; record which pair
  (`[Claude + Codex]`, `[Claude + Antigravity]`, `[Codex + Antigravity]`).
  In a 2-reviewer run this bucket is just "Consensus — both models".
- **Single-source** — raised by only one reviewer.

## Step 4 — Verify the single-source findings

This is the step that makes the report trustworthy — applied fairly to *every*
reviewer's solo findings, since any model can hallucinate an issue. For each
single-source finding, open the referenced code and confirm:

1. It's a **real** problem, not a misread.
2. It's on a **changed** line, not pre-existing.
3. It isn't a nitpick or linter-catchable triviality.

Keep this light — read the cited lines; only dig deeper when it's genuinely
ambiguous. Drop the ones that don't hold, and remember why (you'll list them).

## Step 5 — Report (report-only)

Use this structure. Keep it tight; link `file:line`. Order by severity within
each section. Omit empty sections, and omit the Unanimous section entirely in
2-reviewer runs (rename Majority to plain "Consensus — both models").

```
# 🔍 Multi-review — <scope> · effort <effort>
Reviewers: Claude `/code-review <effort>` · Codex `codex exec` (xhigh)
[· Antigravity `agy` (Gemini 3.1 Pro High) — only if it ran]

## ✅ Unanimous consensus — 3/3 reviewers (<n>)
1. **High** `path/file.py:120` — <summary>
   <one line of why / evidence>

## 🔷 Majority consensus — 2/3 reviewers (<m>)
1. **[Claude + Codex] Med** `path/file.py:88` — <summary>
   <one line of why / evidence>

## 🔸 Single-source, verified (<k>)
- **[Codex] High** `path/file.py:44` — <summary> — verified: <1-line confirmation>

## ⚪ Dropped on verification (<j>)
- [Antigravity] `path/file.py:12` — pre-existing, not introduced by this change

## Reviewer failures
- Antigravity unavailable: <short reason>   ← only if a reviewer failed

## Verdict
<counts of confirmed issues>. <Ship-it, or fix-these-first.>
```

Adapt the emoji/headers to the surrounding conversation if the user prefers
plain text. If every reviewer that ran came back clean: say "No issues found by
Claude, Codex[, or Antigravity]" and skip the empty sections. If Antigravity
failed, never imply it found nothing — list it under Reviewer failures.

Then stop. Offer to fix the top issues or re-run at higher effort if they want —
but don't do it unprompted. Report-only means the user drives the next move.

## Loop mode (opt-in) — fix until the reviewers are quiet

Off by default. Turn it on only when the user asks — "loop", "keep going until
Codex calms down", "fix and re-review until clean", or the `loop[N]` arg. It
changes the contract: the skill will **edit the working tree**. If the user hasn't
clearly opted into edits, say so before the first fix.

Why bounded and not literally infinite: on an *unchanging* diff the models never
go silent — they re-raise the same things or drift onto nitpicks. "Quiet" only
happens when the diff actually improves between rounds, so the loop *fixes* then
re-reviews. And an unbounded loop burns real money/time each round and can thrash
on cosmetic findings — so it converges or caps, it never spins forever.

Each round:

1. Run Steps 2–4 on the **current** diff → the verified findings (consensus +
   verified single-source). Dropped/false-positive findings never count. If
   Antigravity is active, each round gets a **fresh disposable worktree** with
   the current changes carried over, fully removed when the round ends.
2. `new = verified findings not already handled this session` (dedup by file +
   nearby line + underlying issue, same matching as Step 3).
3. **Stop if** any of these — this is what "quiet" means:
   - every active reviewer came back clean, or
   - `new` is empty (nothing left but things already handled or intentionally
     skipped), or
   - round count hit the cap (default **3**, or the `N` in `loopN`).
4. Otherwise **apply minimal, targeted fixes** for the `new` findings, mark them
   handled, and go to the next round. Fix the real problem, not to silence the model.

Hard rules — the difference between a useful loop and a footgun:

- **Only ever fix verified findings** — unanimous, majority, or single-source
  findings that passed Step 4. Never patch code to quiet an unverified or
  dropped finding. Silencing a false positive with a "fix" is worse than the
  finding itself.
- **Cap + converge, never spin.** Default cap 3 rounds; stop the moment a round
  brings nothing new. If the only survivors are Low/nitpick, that's "calm enough" —
  stop rather than thrash.
- **No silent truncation.** If the cap is hit with findings still open, list them
  in the final report — don't imply everything got handled.
- **Keep fixes reviewable.** You're editing their code: after each round note what
  changed (`file:line`, one line each) so it's trivial to eyeball or `git revert`.
  Don't commit — leave changes in the working tree for the user.
- **Loop only makes sense on live changes** (uncommitted or the current branch).
  A historical `commit <sha>` has nothing to iterate on — decline the loop, do a
  single pass.

Final output: the normal Step 5 report for the **last** round (what remains),
preceded by a short **"Fixed across N rounds"** changelog. If it converged clean,
say so plainly: "All reviewers quiet — N rounds, M fixes, nothing left."

## Edge cases

- **Codex missing / logged out at start** → abort (see Prerequisites). Mid-run
  failure (timeout, crash after launch) → deliver what the other reviewers
  produced, clearly labeled, with a note that Codex didn't return.
- **Antigravity fails in any way** → `Antigravity unavailable: <reason>` in the
  report, continue with Claude + Codex. Never abort because of Antigravity.
- **Huge diff** → background reviewers may run long; consider suggesting a lower
  effort or a narrower scope rather than waiting indefinitely.
- **A reviewer flags something about its own invocation** (e.g. a permission
  entry) — that's fair game, include it like any other finding.
- **Host agent isn't Claude Code** (no Skill tool, no built-in `/code-review`) →
  take the Claude side yourself: you, the host model, review the same scope
  with the same criteria as the Codex prompt. Everything else — background
  reviewers, merge, verification, report — is unchanged.
