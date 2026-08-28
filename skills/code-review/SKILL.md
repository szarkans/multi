---
name: code-review
description: >-
  Code review by several models at once — Claude sub-agents, OpenAI Codex, and
  a cheap third reviewer via OpenCode — reconciled into one report. Reviews
  whatever is named: a diff, a branch, specific files, one function, a legacy
  module, a whole repo. Use for any review request, a second or third opinion,
  a cross-check before a PR, or "code-review", "multi", "consensus review".
allowed-tools: Bash, Read, Grep, Glob, Agent, TodoWrite
argument-hint: "[what to review, in words] [lite|normal|ultra] [haiku|sonnet|opus|fable] [low|medium|high|xhigh|max]"
---

# Multi-model code review

!`sh -c 'for p in "$CLAUDE_PLUGIN_ROOT/scripts" "$HOME/.claude/skills/multi/scripts" "./.claude/skills/multi/scripts"; do [ -x "$p/probe.sh" ] && { "$p/probe.sh"; echo "scripts-dir: $p"; exit 0; }; done; echo "probe: NOT FOUND — locate scripts/probe.sh in this plugin and run it yourself"'`

Several models read the same code, and you decide what reaches the user. That
is the whole idea: one model invents problems and walks past real ones, and you
cannot tell which from a single report. Independent models disagree, and the
disagreement is the signal.

You are the judge, not a dispatcher. The reviewers propose; they do not vote,
and none of them gets the last word. When they conflict, open the code and
decide.

This is normally reached at the end of a session — work is done, PR or push
comes next. Act like it: the question is "is this ready", not "here are some
observations".

`$SCRIPTS` below is whatever the probe printed as `scripts-dir:`.

## The gate

From the probe lines above — they are already there, do not re-run it.

**No second reviewer family → stop.** This is multi-model review; the review
pipeline can run two non-Claude families, Codex and OpenCode — without at
least one of them there is nothing here that a single-model review does not
already do. OpenRouter and Gemini are real second families, but this pipeline
cannot run them as reviewers yet: they serve `/multi:ask`, not this skill.
Say which is missing and point at `/multi:setup`. Do not quietly deliver a
one-model review wearing a three-model label.

Anything else missing is a note, not a stop: no OpenCode, no ponytail, not a
git repo (fine — then the target is files, not a diff). Name what was missing
in the report and carry on.

Whatever is missing, point them at `/multi:setup` to connect it — it walks
through this step by step and does not need them to know any of the above.

## Decide what you are reviewing

**Whatever the user named.** A diff, a branch, two files, one function, a line
range, a module nobody has touched in three years, the whole repository. There
is no fixed vocabulary here and no menu — read what they wrote and work out
what they mean, the way a colleague would.

When nothing was named, in this order:

1. **What this session was about.** If you just wrote or changed something, that
   is the target — you know which files, what the task was, where you were
   unsure, what you fixed blind. That is better than a diff, which in a dirty
   tree also holds debug leftovers and unrelated edits, and which misses the old
   code the change leans on.
2. **The branch**, if it is ahead of main and the tree is clean.
3. **The uncommitted diff** otherwise.

Ask only when the answer genuinely changes what gets reviewed and you cannot
tell — dirty tree *and* they mentioned a PR, say. Never open with a
questionnaire: this skill runs at the end of a session, sometimes inside an
autonomous run, and three questions there are worse than a wrong guess you
announced. Guess, say what you guessed, let them correct you.

Whatever you settle on, resolve it into **concrete paths, or a concrete git
range, before dispatching**. Every reviewer must look at the same thing —
otherwise "two of them agreed" means nothing, they just happened to read the
same file. If the target is vague, resolve it and say what you resolved it to.

## Say what you are about to do

**Always, before launching anything.** Short, then go — this is not a request
for permission, and you do not wait for an answer:

```
Reviewing: <target, and where it came from — "what we just did", "branch vs main", "you asked for src/auth.py">
           <when $REPO is not the session's own checkout, show the resolved path so a wrong-tree review is caught before it runs>
Running now: Codex <effort> · OpenCode <model> · ponytail          <— or why one is missing
Then: <what decides the Claude spend>
```

If they wanted something else they will say so, and interrupting is cheaper
than an interrogation.

## Launch everything free, immediately

Codex, OpenCode and the ponytail lens cost nothing per run and take 30–70
seconds wall clock. There is never a reason to hold them back or make them
conditional on a mode. Start the two external ones **in the background, both at
once** — OpenCode spends about a minute just warming up — and do everything
else while they run.

```bash
RUN="$($SCRIPTS/run-dir.sh --slug <two-to-four words: the project and the job, e.g. skills-fixing-multi>)"

# The tree under review. Usually the session's own repo; set REVIEW_DIR to a
# path or a different worktree when THAT is the target. Resolve it once: cwd
# resets between these blocks, so without an explicit path the reviewers silently
# read the session checkout and can "agree" on an empty diff.
REPO="$(git -C "${REVIEW_DIR:-.}" rev-parse --show-toplevel)"

# Isolate. The reviewers run on a COPY of the work tree, never the live one:
# a Bash sub-agent or an opencode flipped to bash by a hostile repo config can
# run `git checkout -- .` and wipe uncommitted work, and the copy takes that hit
# instead. The copy also drops the repo's opencode config, so a hostile
# .opencode/agent/plan.md cannot re-enable write+bash. It carries the diff as a
# file (review.diff) so nobody needs git in it — opencode under --agent plan
# cannot run git at all. Pass the SAME --diff spec you review with; drop it for a
# whole-code (non-diff) review.
COPY="$($SCRIPTS/snapshot.sh --repo "$REPO" [--diff <spec>] --dest "$RUN/snapshot")"
# If the snapshot failed (a typo'd --diff, a permission error), $COPY is empty and
# every reviewer would fall back to cwd — the live tree. STOP instead: that is the
# data-loss path this exists to close. Fix the target and re-run, don't review.
[ -n "$COPY" ] || { echo "snapshot failed — not reviewing the live tree"; exit 1; }
# Snapshot ONCE. Persist the path so later blocks reuse this copy instead of
# re-running snapshot — a re-run rm -rf's and rebuilds the dir while the
# background ask.sh (and the sub-agents) are still reading it.
echo "$COPY" > "$RUN/copy-path"

# collect-context reads the ORIGINAL, not the copy: it only reads, and it needs
# the .git the copy does not carry to decide which rule files the change touched.
$SCRIPTS/collect-context.sh --repo "$REPO" [--diff <spec>] [--paths "<paths>"] > "$RUN/ctx.md"

# Everything that a reviewer executes points at $COPY. With --diff, add
# --diff-artifact review.diff so the prompt hands them the diff file instead of a
# git command that would fail in the copy.
$SCRIPTS/review-prompt.sh --repo "$COPY" --target "<in words>" [--diff <spec> --diff-artifact review.diff] [--paths "<paths>"] \
                          [--focus "<user text>"] --context "$RUN/ctx.md" > "$RUN/review.prompt.md"
$SCRIPTS/ask.sh --repo "$COPY" --question-file "$RUN/review.prompt.md" --out-prefix "$RUN/review" \
                --backend "codex,opencode:<model from probe>" --fallback <from probe> \
                --effort <low|medium|high|xhigh|max> --timeout "${MULTI_REVIEW_TIMEOUT:-900}"
```

`run-dir.sh` prints this session's own directory, `/tmp/multi/<session>--<slug>`,
and creates it. Two sessions reviewing at once used to share fixed `/tmp` names
and overwrite each other's files. Shell variables do not survive between
commands, so repeat `RUN=` and `REPO=` in every later block that needs them.
`COPY` is the exception: snapshot it **once** (above), then in later blocks read
the persisted path back with `COPY="$(cat "$RUN/copy-path")"` — never re-run
`snapshot.sh`, or you rebuild the copy out from under the reviewers already
reading it. `--slug` only labels the directory the first time, so a different
wording later still lands in the same place. Runs older than a week are swept,
and the snapshot with them.

`--diff` is what makes it a *change* review; leave it off and the reviewers read
the actual code instead, with old code fully in scope. `--paths` narrows hard for
`collect-context` and the sub-agents' scope, but note the limit in a diff review:
`snapshot.sh` puts the *whole* diff in `review.diff`, so there `--paths` reaches
the reviewers as a focus instruction, not a hard cut — do not rely on it to
withhold a path from them.
`--target` is always required — it is the human sentence, and it is what keeps
the reviewers pointed at the same thing. `--repo` is the *directory* a backend
works in: `$REPO` (the original) for `collect-context`, which only reads and
needs the real `.git`; `$COPY` (the isolated snapshot) for `review-prompt` and
`ask.sh`, and for the sub-agents. Snapshot the same `--diff` you review with, so
the copy's `review.diff` matches the change.

The probe at the top of this file ran with no `--repo`, so its `repo:`, branch,
dirty-file and ahead-of-main numbers describe the **session checkout**. When
`$REPO` is a different worktree, those numbers are for the wrong tree — re-run
`$SCRIPTS/probe.sh --repo "$REPO"` to orient on the real target before you trust
them.

`collect-context.sh` gathers the repo's `CLAUDE.md`/`AGENTS.md` and the
`.claude/rules/*.md` matching the target, and every reviewer gets it. This is
what separates this from three models guessing: an external reviewer that does
not know the project's settled decisions spends its findings re-litigating them.

**The ponytail lens** — invoke the `ponytail:ponytail-review` skill on the same
target whenever the probe found it. It hunts one thing, over-engineering, and
that keeps the defect reviewers out of matters of taste entirely (see below).
Its findings are a different kind of thing and never mix with defects: they get
their own section and cannot corroborate or contradict a bug.

> If ponytail mode is *active*, its `SubagentStart` hook injects the YAGNI
> ruleset into every sub-agent, including the ones hunting bugs. If findings
> start reading like simplification advice, that is why; `PONYTAIL_SUBAGENT_MATCHER`
> is the fix. Mention it once, move on.

## Then decide how much Claude to spend

The external reviewers are free; your sub-agents are the user's money. So do
not guess the depth up front — **wait for the free results and decide on
evidence**. A two-line change both reviewers called clean does not need three
sub-agents. A change where Codex reports two HIGH and OpenCode disagrees with
one of them does.

Say the decision in one line when you make it: *"going to normal — Codex found
two HIGH, OpenCode contradicts one."*

An explicitly named mode skips all of this. Obey it.

| | Claude sub-agents | when |
|---|---|---|
| `lite` | `correctness` only | small, low-risk, external reviewers agree and found little |
| `normal` *(default)* | `correctness` · `security` · `design` | anything heading for a PR |
| `ultra` | those three, plus `execution`, plus an adversarial second Codex pass (`--adversarial`), plus one `verify` per single-source finding | expensive to get wrong, or asked for |

The adversarial pass needs Codex specifically; without it, `ultra` runs without
that pass — the rest of the mode is unchanged.

Spawn them **in parallel, in one message**. Give each the target, the paths or
range, the contents of `$RUN/ctx.md`, and the user's own words if there
were any. Point them at `$COPY`, not `$REPO` — *read the files in `$COPY`* — and, **only
when you snapshotted a diff**, add *the change is in `$COPY/review.diff` (statuses
in `review.manifest`)*. In a whole-code review (no `--diff`) there is no
`review.diff` — do not point them at one that isn't there. These reviewer agents
have **no Bash tool** (they read with Read/Grep/Glob), so — unlike the CLI
backends, which the copy sandboxes by running *in* it — they cannot run a
destructive command against the live tree at all. That is the enforced half of
the #14 fix: a sub-agent's shell would otherwise start in the session checkout,
where a stray `git checkout -- .` wipes uncommitted work no matter what the
prompt says. The copy still gives them the code and the diff to read; it just is
not what protects the live tree from them — removing the shell is.

**Model**: the argument if given, else `MULTI_REVIEWER_MODEL` from the probe, else
the agent files' default (Sonnet). **No mode raises it on its own** — `ultra`
buys depth through more angles and real verification, not a bigger model.

**`ultra` is not a deeper code review — it reviews whether the task got done.**
Was there a plan and was it followed; is the thing actually finished or only
finished-looking; what was silently skipped; what will detonate later. That
needs the task context — the plan, the spec, the conversation. Hand `execution`
what you actually know about the job. Without any of that, `ultra` degrades to
`normal` plus an architecture angle, and you should say so rather than pretend.

## Judge

Normalize everything to `{file, line, severity, claim}`. Codex and OpenCode
both answer the unified review prompt as
`FILE:LINE | HIGH|MEDIUM|LOW | reason`, with repo-relative paths. OpenCode's
file has two parts: `## <model>` listing every tool call it made, then
`## Answer` with what it wrote in that unified format.
Sub-agents report `FILE:LINE | SEVERITY | confidence NN` with two lines under
it.

**Read OpenCode's call list before its findings.** It is there to answer one
question: did this reviewer actually look at the code it is talking about? A
finding about a file that never appears in the call list was invented, and it
goes in `Dropped`. `(none — this reviewer answered without opening anything)`
means the whole report is guesswork. `NO ANSWER` means it ran and said
nothing: that reviewer was absent, say so as `Codex/Opencode FAILED: <reason>`
from the one-line text in `*.dead` rather than reading silence as agreement.

Bucket by *the underlying problem*, not by wording — the same bug gets three
different descriptions:

- **Corroborated** — two or more reviewers from different families (Claude /
  Codex / OpenCode). Leads the report; independent agreement is the strongest
  evidence this pipeline produces.
- **Single-source** — one reviewer. Check each before the user sees it: open the
  cited lines, confirm it is real and reachable. In `ultra`, spawn one
  `verify` per finding instead and take its verdict.
- **Minor** — a real defect that is simply small. Not verified — that costs more
  than it is worth — and listed at the bottom, one line each.
- **Dropped** — only two things belong here: the code contradicts it, or (in a
  diff review) it predates the change. "Too small" is never a reason.

Rules that make the report worth reading:

- **Same scepticism for everyone.** Codex being expensive does not make it
  right; the cheap reviewer being cheap does not make it wrong. In measurement
  here the cheap one caught a real bug Codex missed.
- **Disagreements are surfaced, not averaged.** Read the code, decide, and put
  the disagreement in the report — where good reviewers split is where the user
  should look.
- **Nothing raised disappears silently.** Every finding lands in a bucket, and a
  dropped one carries its reason.
- **Answer the user's own words first**, if they gave any — even when the answer
  is "no, that path is fine, here is why".

## Report

Report only: no edits, no commits, no PR comments. This is the default shape,
not a schema — drop empty sections, and match the surrounding conversation.

```
# 🔍 Multi-review — <target> · <mode>
Reviewers: Claude <n> · Codex <effort> · OpenCode <model> · ponytail
<one line if something was missing or died, and why>

## ✅ Corroborated (<n>)
1. **HIGH** `path/file.py:120` — <what is wrong>
   <the concrete failure case> — Codex + correctness

## 🔸 Single-source, verified (<m>)
- **MEDIUM** `path/file.py:88` — <what is wrong> — [OpenCode] verified: <what you confirmed>

## ⚖️ Reviewers disagreed (<k>)
- `path/file.py:44` — Codex calls it a race; correctness says the caller holds the lock. <Your call, and why.>

## 🪒 Simplicity — ponytail (<p>)
- `path/file.py:52-71` — delete: retry wrapper around an idempotent local call.

## 🔹 Minor (<q>)
- `path/file.py:12` — [correctness] log line interpolates the wrong id; misleads during an incident.

## ⚪ Dropped (<j>)
- [Codex] `path/x.py:12` — pre-existing, not introduced by this change

## Verdict
<Ship it, or fix these first.> <If ultra: is the task actually done, and what is missing.>
```

Then stop. Offer to fix the top findings or to re-run deeper — do not do either
unprompted.

## Loop mode (opt-in) — fix, re-review, repeat

Only when explicitly asked ("loop", "until it's clean"). It edits the working
tree; say so before the first edit if they were not explicit.

Each round: re-run the reviewers → take what survived judging → fix what is new
→ go again. Stop when a round brings nothing new, when only `Minor` is left, or
at the cap (default 3). Never fix a dropped finding — silencing a false
positive is worse than the finding. Never commit. After each round list what
changed as `file:line` one-liners. If the cap is hit with findings open, say so.

## Edge cases

- **Huge target** — say up front it will be slow and shallow, and offer a
  narrower one, rather than quietly reviewing four hundred files badly.
- **Lockfiles, generated code, vendored trees** — say so and skip the external
  reviewers; there is nothing there for them.
- **A reviewer hangs** — the caller passes
  `--timeout "${MULTI_REVIEW_TIMEOUT:-900}"` to `ask.sh`; that value bounds each
  backend, and a failed run writes the reason as the one-line `.dead` text, so
  a hang arrives as `... FAILED: ...`, never as an empty file.
  Treat that reviewer as absent and name it in the report. A reviewer still
  writing is alive, however long it takes. Never block the whole review on one
  backend.
- **OpenCode falls back to its free model** — its output says so. Repeat it in
  the reviewer line; the user is entitled to know which model actually ran.
