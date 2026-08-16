---
name: multi-review
description: >-
  Review a diff with three independent models at once — Claude sub-agents,
  OpenAI Codex, and a third cheap reviewer via OpenCode — then judge their
  findings into one ranked report. Use whenever the user wants a code review,
  a second or third model's eyes on a change, a cross-model or "double"
  review, a higher-confidence pass before opening a PR or merging, or says
  "multi-review", "mcr", "consensus review", "have Codex review this", or
  "cross-check my changes". Prefer this over a single-model review whenever
  more than one reviewer is available.
allowed-tools: Bash, Read, Grep, Glob, Agent, TodoWrite
argument-hint: "[haiku|sonnet|opus|fable] [low|medium|high|xhigh|max] [--ponytail] [quick|normal|ultra] [uncommitted|branch <base>|commit <sha>]"
---

# Multi-model code review

Reviewer availability, checked before you read this:

!`sh -c 'for p in "$CLAUDE_PLUGIN_ROOT/skills/multi-review/scripts" "$HOME/.claude/skills/mcr/skills/multi-review/scripts" "$HOME/.claude/skills/multi-review/scripts" "./.claude/skills/multi-review/scripts"; do [ -x "$p/probe.sh" ] && { "$p/probe.sh"; echo "scripts-dir: $p"; exit 0; }; done; echo "probe: NOT FOUND — locate scripts/probe.sh in this skill and run it yourself"'`

Three models look at the **same diff with the same project rules**, and one
judge — you — decides what reaches the user. The reviewers propose; they do not
vote and they do not get the last word. Two of them are cheap and external, so
the user's Claude budget goes almost entirely into judging rather than reading.

`$SCRIPTS` below means whatever the probe printed as `scripts-dir:` — the
scripts ship inside this skill, so they are there under every install method.

## Step 0 — the gate

Read the availability lines above. They are already there; do not re-run the
probe.

- **`codex: MISSING` or `NOT LOGGED IN` → stop.** Tell the user plainly: this
  skill is multi-model review, and without Codex there is no second model, so
  there is nothing here that a plain single-model review does not already do.
  Point them at `codex login` (or installing Codex), or at running the built-in
  `/code-review` instead. Do not silently fall back — that would hand them a
  one-model review wearing a three-model label.
- **`opencode: MISSING` or `NO USABLE MODEL` → carry on with two reviewers.**
  Say once, in the final report's reviewer line, that the third slot was empty
  and why. Never block on it, and never probe for it again during this run.
- **`ponytail: OK` → the `--ponytail` lens is available** (Step 3). It is never
  automatic. `ponytail: absent` → the flag has nothing to run; say so only if
  the user asked for it.
- **`repo: NOT A GIT REPOSITORY` → stop.** Everything here is diff-scoped.
- **`dirty-files: 0` with no branch/commit scope given → stop.** There is
  nothing to review; say so.

## Step 1 — arguments, mode, scope

**Arguments.** `$1` is the model for the Claude review sub-agents, `$2` is
Codex's reasoning effort, and `--ponytail` adds the simplicity lens. Every one
is optional. Match them by *value* rather than by position — the vocabularies
don't overlap, so `/mcr:multi-review high ultra` means what it looks like:

| token | meaning | default |
|---|---|---|
| `haiku` `sonnet` `opus` `fable` | model for the Claude reviewers | Sonnet, or `MCR_REVIEWER_MODEL` |
| `low` `medium` `high` `xhigh` `max` | Codex reasoning effort | set by the mode |
| `--ponytail` | add the over-engineering lens (Step 3) | off |
| `quick` `normal` `ultra` | depth | `normal` |
| `uncommitted` · `branch <base>` · `commit <sha>` | what to review | `uncommitted` |

An explicit argument always beats the mode's default: `ultra low` really does
mean the full fleet with Codex thinking cheaply.

If the model argument is `haiku`: say `Серьёзно?` to the user — in whatever
language the conversation is in — and then stop. Nothing else, no explanation.
Once the user confirms, run the review on Haiku exactly as asked, normally and
without further comment. If they change their mind, take the model they name
instead.

**Mode** — from the user's words, defaulting to `normal`:

| | reviewers | use when |
|---|---|---|
| `quick` | Codex (effort `low`) + OpenCode. No Claude sub-agents. | The everyday pass. Cheapest — replaces a plain single-model review and costs the user almost no Claude tokens. |
| `normal` | Codex (`medium`) + OpenCode + `mcr-correctness` + `mcr-security` | Default. Anything going into a PR. |
| `ultra` | Codex (`high`) + a second adversarial Codex pass + OpenCode + `mcr-correctness` + `mcr-security` + `mcr-design`, and every surviving finding independently verified | Before merging something that is hard to undo, or when the user asks for depth. Minutes and real money — do not pick it on your own. |

The ponytail lens is orthogonal to the mode: `--ponytail` adds it to any of
them.

Words like "быстро", "по-быстрому", "just a quick look" → `quick`. "Тщательно",
"максимально", "ultra", "не жалей" → `ultra`. Ambiguous → `normal`, and say
which one you picked in the report header.

**Scope** — all reviewers must see exactly the same range:

- `uncommitted` — staged + unstaged + untracked. Default when the tree is dirty.
- `branch` — the branch against its base. Resolve the base explicitly:
  `git merge-base main HEAD` (or `master`, or whatever the user named).
- `commit <sha>` — one commit.

If the tree is dirty **and** the user said nothing about scope, take
`uncommitted` and say so in one clause. Only ask when the tree is dirty *and*
they mentioned a branch or PR — that genuinely changes what gets reviewed.

## Step 2 — assemble the project rules

```bash
$SCRIPTS/collect-context.sh --scope <scope> [--ref <base-or-sha>] > /tmp/mcr-ctx.md
```

This gathers the repo's `CLAUDE.md`/`AGENTS.md`, the `.claude/rules/*.md` files
whose names match the changed paths, and any nested guidance beside the changed
files. Pass the resulting file to **every** reviewer.

This step is what separates this skill from three models guessing
independently. External reviewers know nothing about the project's settled
decisions, and without the rules they spend their findings re-litigating them.

## Step 3 — launch the reviewers

Start the two external reviewers **in the background first** — OpenCode alone
spends about a minute on cold start — then do the Claude side while they run.

```bash
# background, both at once
$SCRIPTS/review-codex.sh    --scope <scope> [--ref <r>] --effort <low|medium|high> \
                            --context /tmp/mcr-ctx.md --out /tmp/mcr-codex.txt
$SCRIPTS/review-opencode.sh --scope <scope> [--ref <r>] \
                            --context /tmp/mcr-ctx.md --out /tmp/mcr-opencode.txt
```

In `ultra`, also start a second Codex pass with `--adversarial` (writing to a
different `--out`); it challenges the approach instead of the lines.

**Then, per mode, spawn the Claude reviewers in parallel in a single message**
(`mcr-correctness` and `mcr-security` for `normal`; plus `mcr-design` for
`ultra`; none for `quick`). Give each one the scope, the base/sha, and the
contents of `/tmp/mcr-ctx.md`.

**Which model they run on**, first match wins:

1. the model argument, if the user gave one;
2. `MCR_REVIEWER_MODEL`, which the probe prints as `reviewer-model:`;
3. otherwise the agent files' own default, Sonnet.

**No mode ever upgrades the model on its own, `ultra` included.** `ultra` buys
its depth elsewhere — Codex at `high`, a second adversarial Codex pass, a third
reviewer angle, and per-finding verification. If the user wants a bigger model
they will say so; spending their budget for them is not this skill's call.

**If the `mcr-*` agents do not exist**, this skill was installed on its own
(`npx skills add`) rather than as a plugin — the agents are a plugin-level
component and did not come along. Spawn `general-purpose` sub-agents instead
and give them the review brief inline: one for correctness (logic, state,
error paths, races), one for security (authz, injection, secrets, data
exposure), each told to report only defects on changed lines with a confidence
of 80+, in the `FILE:LINE | SEVERITY | claim` shape. Say once in the report
that the specialised reviewers were unavailable, and mention that installing
the plugin brings them.

**The ponytail lens** — only when the user passed `--ponytail` *and* the probe
found it. It is off by default because it answers a different question than the
rest of the pipeline, and most reviews don't want it mixed in. If `--ponytail`
was passed but the probe says `absent`, say so in one line and carry on.

Invoke the `ponytail:ponytail-review` skill against the same scope. It hunts one
thing — over-engineering — and says so itself: what to delete, what the standard
library already ships, which abstraction has exactly one implementation. Run it
in the main thread rather than a sub-agent: its output is one terse line per
finding, so it is cheap, and its own hooks make sub-agent behaviour harder to
reason about (below).

Its findings are a **different kind of thing** from the defect reviewers'. "This
retry wrapper is pointless" cannot corroborate or contradict "this is a race
condition". Never merge the two — keep the lens in its own bucket all the way
through to its own section of the report.

> **Interaction worth knowing.** When ponytail mode is *active*, its
> `SubagentStart` hook injects the YAGNI ruleset into **every** sub-agent —
> including `mcr-correctness` and `mcr-security`, whose job is finding bugs, not
> shortening code. If findings start reading like simplification advice, that is
> why. The fix is `PONYTAIL_SUBAGENT_MATCHER`, a regex naming which agent types
> should get the injection; anything that does not match `mcr-` keeps the defect
> reviewers clean. Mention it once if you see the bias, and move on.

**Watchdog.** A background reviewer that has produced no output for 60 seconds
gets one kill-and-restart, then another 60 seconds. Still silent → treat it as
absent, note it in the report, move on. A reviewer that is still writing is
alive however long it takes. Never block the whole review on one backend.

## Step 4 — judge

You are the judge. The reviewers disagree by design: that is the signal.

Normalize everything to `{file, line, severity, claim}`. Codex reports as
`- [P1] <title> — <abs path>:<line>-<line>` with the explanation indented below
(P1/P2/P3 → high/medium/low) and uses absolute paths — convert them to
repo-relative. OpenCode reports `FILE:LINE | SEVERITY | reason`. The sub-agents
report `FILE:LINE | SEVERITY | confidence NN` with two lines under it.

Then bucket by *the underlying problem*, not by wording — the same bug gets
described three different ways:

- **Corroborated** — flagged by two or more reviewers from different families
  (Claude / Codex / OpenCode). These lead the report. Independent agreement is
  the strongest evidence this pipeline can produce, so raise severity one step
  when a `medium` is corroborated by all three.
- **Single-source** — raised by exactly one. Every one of these gets checked
  before the user sees it, because each reviewer hallucinates confidently:
  - `quick` / `normal`: check it yourself — open the cited lines, confirm the
    problem is real, is on a line this change touched, and is reachable.
  - `ultra`: spawn one `mcr-verify` per finding, in parallel, and take its
    verdict. `REFUTED` findings are dropped.
- **Minor** — real but small: nitpicks, style, naming, a missing test, anything
  a reviewer marked `LOW` or hedged on. These do **not** get dropped and they do
  not get verified either — that would cost more than they are worth. They go at
  the bottom of the report, one line each, for the user to skim.
- **Dropped** — did not survive verification. Only two things belong here: a
  claim the code contradicts, and a problem that predates the change. "Too
  minor" is never a reason to drop; that is what **Minor** is for.

Three rules that make the report trustworthy:

- Apply the same scepticism to every source. Codex being expensive does not
  make it right, and the cheap reviewer being cheap does not make it wrong — in
  practice the cheap one catches things the expensive one misses.
- When reviewers **contradict** each other on the same lines, do not average
  them. Read the code, decide, and put the disagreement in the report — the
  places where good reviewers split are exactly where the user should look.
- **Nothing a reviewer raised disappears silently.** Every finding lands in one
  of the buckets above, and a dropped one carries its reason. The user should
  be able to tell what was found from what survived; deciding for them which
  small thing was not worth mentioning is exactly how a real problem gets lost.

## Step 5 — report

Report only. No edits, no commits, no PR comments — the user decides what
happens next.

```
# 🔍 Multi-review — <scope> · <mode>
Reviewers: Claude <n sub-agents> · Codex <effort> · OpenCode <model><· ponytail>
<one line if a reviewer was absent or died, and why>

## ✅ Corroborated (<n>)
1. **HIGH** `path/file.py:120` — <what is wrong>
   <the concrete failure case> — flagged by Codex + mcr-correctness

## 🔸 Single-source, verified (<m>)
- **MEDIUM** `path/file.py:88` — <what is wrong> — [OpenCode] verified: <what you confirmed>

## 🪒 Simplicity — ponytail (<p>)
- `path/file.py:52-71` — delete: retry wrapper around an idempotent local call.
- `path/other.ts:4` — native: a dependency for one format call; `Intl.DateTimeFormat`.

## ⚖️ Reviewers disagreed (<k>)
- `path/file.py:44` — Codex calls it a race; mcr-correctness says the caller
  holds the lock. <Your call, and why.>

## 🔹 Minor (<q>)
- `path/file.py:12` — [mcr-correctness] variable shadows the outer `items`.
- `path/api.ts:77` — [OpenCode] new branch has no test.

## ⚪ Dropped (<j>)
- [Codex] `path/x.py:12` — pre-existing, not introduced by this change
- [OpenCode] `path/y.py:5` — false positive: <reason>

## Verdict
<n corroborated + m verified, j dropped>. <Ship it, or fix these first.>
```

Drop empty sections rather than printing zeros. If every reviewer came back
clean, say so in one line and stop — do not pad it into a report.

Then stop. Offer to fix the top findings or to re-run at a higher mode, but do
not do either unprompted.

## Loop mode (opt-in) — fix, re-review, repeat

Only when the user explicitly asks ("loop", "until it's clean", `loop[N]`).
It changes the contract: the working tree gets edited. Say so before the first
edit if they were not explicit about that.

Each round: run Steps 2–4 → take the surviving findings → `new` = those not
already handled this session → apply minimal targeted fixes → next round.

Stop when a round brings nothing new, when everything left is `LOW`, or at the
cap (default **3**, or the N the user gave). Hard rules:

- **Only ever fix findings that survived Step 4.** Patching code to silence a
  dropped finding is worse than the finding.
- **Never** commit. Leave the changes in the working tree.
- After each round, list what changed as `file:line` one-liners so it is
  trivial to eyeball or revert.
- If the cap is hit with findings still open, list them. Never imply everything
  was handled.
- Loop only makes sense on live changes. A historical commit has nothing to
  iterate on — decline the loop and do a single pass.

## Edge cases

- **Huge diff** — reviewers will be slow and shallow. Say so up front and offer
  a narrower scope rather than quietly reviewing 4000 lines badly.
- **Diff is all lockfiles, generated code, or vendored files** — say that and
  skip the external reviewers; there is nothing for them to find.
- **A reviewer flags this skill's own invocation** (a permission entry, a
  script) — that is a normal finding, include it.
- **OpenCode present but the configured model is broken** — that is what the
  watchdog is for. Note it once and suggest `MCR_OPENCODE_MODEL`; do not debug
  it mid-review.
