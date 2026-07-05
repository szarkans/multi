# Multi Code Review

> Consensus code review: **Claude + OpenAI Codex** (and optionally **Google
> Antigravity / Gemini**) review the same diff in parallel, then their findings
> are reconciled into one trustworthy report.

[Русская версия →](README.ru.md) · [中文版 →](README.zh.md)

One model reviewing your code can hallucinate an issue — or miss a real one.
Independent models reviewing the **same diff at the same time** catch more, and
the issues they *agree* on are the ones worth fixing first. This skill runs the
reviewers in parallel, cross-verifies every finding only one model raised, drops
the false positives, and gives you a single ranked report.

## How it works

```
                 ┌────────────────────────┐
        ┌───────▶│ Claude  (/code-review) │─────┐
        │        └────────────────────────┘     │
 same   │        ┌────────────────────────┐     ▼        ┌─────────────────┐
 diff ──┼───────▶│ Codex   (codex exec)   │──▶ merge ────▶│ consensus report│
        │        └────────────────────────┘     ▲        └─────────────────┘
        │        ┌────────────────────────┐     │
        └───────▶│ Antigravity (agy)*     │─────┘
                 └────────────────────────┘   * optional third reviewer
```

1. **Scope is settled** — uncommitted changes (default), branch vs base, or a
   single commit. All reviewers look at exactly the same range.
2. **Reviewers launch in parallel** — Codex runs in the background at `xhigh`
   reasoning; Antigravity (if installed) runs `Gemini 3.1 Pro (High)` inside a
   disposable git worktree so it can never touch your real repo; Claude reviews
   meanwhile.
3. **Findings are merged** into confidence buckets:
   - ✅ **Unanimous** — all three reviewers flagged it (highest confidence)
   - 🔷 **Majority** — two of three agree (the pair is named)
   - 🔸 **Single-source, verified** — one reviewer raised it, and the code was
     opened and checked before it reached you
   - ⚪ **Dropped** — false positives, listed with the reason they were dropped
4. **Report-only by default** — no edits, no PR comments; you decide what to do.
   An opt-in **loop mode** instead fixes verified findings and re-reviews until
   the reviewers go quiet (bounded, 3 rounds by default).

## Requirements

| Dependency | Role | Required? |
|---|---|---|
| [Claude Code](https://code.claude.com) or any [Agent Skills](https://agentskills.io)-compatible agent | Host + first reviewer | ✅ yes |
| [OpenAI Codex CLI](https://github.com/openai/codex), logged in | Second reviewer | ✅ yes — the skill **aborts without it** (a "multi" review with one model is pointless) |
| Google Antigravity CLI (`agy` ≥ 1.0.15), logged in | Third reviewer (Gemini) | ⬜ optional |
| `git` | Diffs, scopes, worktree isolation | ✅ yes |

Setting up Codex:

```bash
npm install -g @openai/codex
codex login
```

The skill probes each reviewer **once** and caches the result in
`~/.config/multi-code-review/state.json` — later runs don't re-check. If
Antigravity isn't installed, you're told once that it's an optional extra, and
it is never mentioned again unless you explicitly ask ("with antigravity" /
"re-check antigravity").

## Install

### Claude Code — via plugin marketplace (recommended)

```
/plugin marketplace add szarkans/multi-code-review
/plugin install multi-code-review@szarkans-skills
```

### Any agent — via the skills CLI

[`npx skills`](https://github.com/vercel-labs/skills) installs the skill into
Claude Code, Codex CLI, Cursor, OpenCode, Gemini CLI, and dozens of other
agents at once:

```bash
npx skills add szarkans/multi-code-review
```

Or target specific agents:

```bash
npx skills add szarkans/multi-code-review -a claude-code -a cursor -a opencode
```

### Manual

```bash
git clone https://github.com/szarkans/multi-code-review
mkdir -p ~/.claude/skills
cp -r multi-code-review/skills/multi-code-review ~/.claude/skills/
```

(For other agents, copy to that agent's skills directory instead.)

## Usage

Just ask for it in plain language — the skill triggers itself:

```
multi-code-review my uncommitted changes
have Codex and Claude both review this branch against master
consensus review at max effort before I open the PR
cross-check commit abc1234 with codex
```

**Effort** (`low` … `max`, default `high`) drives the Claude side; Codex always
runs at `xhigh`, Antigravity always runs `Gemini 3.1 Pro (High)`.

**Scopes**: uncommitted (default) · branch vs base · single commit.

**Loop mode** (opt-in — the skill will edit your working tree):

```
multi-code-review, loop until clean
multi-code-review loop5 my branch vs main
```

Fixes only *verified* findings, re-reviews, stops when a round brings nothing
new or the cap (default 3 rounds) is hit. Never commits — changes stay in the
working tree for you to review.

**Antigravity control**:

```
multi-code-review with antigravity      ← re-probe / enable the third reviewer
multi-code-review without antigravity  ← skip it for this run only
```

## Running in agents other than Claude Code

The skill is written against the open [Agent Skills](https://agentskills.io)
format, so any compatible host can run it. The one Claude-Code-specific piece —
the built-in `/code-review` — has a documented fallback: in other hosts, the
host model itself performs that side of the review with the same criteria as
the Codex prompt. Everything else (background reviewers, worktree isolation,
merge, verification) is plain `git` + shell and works anywhere.

| Host | Install | Notes |
|---|---|---|
| **Claude Code** | `/plugin marketplace add szarkans/multi-code-review` | Native: uses built-in `/code-review` as the Claude side |
| **Cursor / OpenCode / Gemini CLI / others** | `npx skills add szarkans/multi-code-review` | Host model takes the first-reviewer role |
| **Codex CLI as host** | `npx skills add szarkans/multi-code-review -a codex` | Works, but the host and the second reviewer are then the same model family — you lose some independence; prefer a non-OpenAI host |

## State file

`~/.config/multi-code-review/state.json` remembers which reviewers are
known-good so runs stay fast:

```json
{ "codex": "ok", "antigravity": "skipped" }
```

- Delete the file to force a full re-probe.
- `"antigravity": "skipped"` means "not installed, user informed once, stop
  asking" — flip it by saying "re-check antigravity" or by deleting the file.

## Example report

```
# 🔍 Multi-review — uncommitted · effort high
Reviewers: Claude `/code-review high` · Codex `codex exec` (xhigh) · Antigravity `agy` (Gemini 3.1 Pro High)

## ✅ Unanimous consensus — 3/3 reviewers (1)
1. **High** `api/auth.py:120` — session token compared with `==`, timing-unsafe
   All three flagged the non-constant-time comparison on a secret.

## 🔷 Majority consensus — 2/3 reviewers (1)
1. **[Claude + Codex] Med** `worker.py:88` — retry loop can double-charge on timeout

## 🔸 Single-source, verified (1)
- **[Antigravity] Med** `models.py:44` — nullable FK dereferenced without guard — verified: reproduced on empty fixture

## ⚪ Dropped on verification (1)
- [Codex] `utils.py:12` — pre-existing, not introduced by this change

## Verdict
3 confirmed issues (1 High). Fix the token comparison before merging.
```

## Repo layout

```
.claude-plugin/
  plugin.json         ← plugin manifest
  marketplace.json    ← this repo is also a Claude Code plugin marketplace
skills/
  multi-code-review/
    SKILL.md          ← the skill itself (Agent Skills format)
    evals/evals.json  ← behavioral test cases / executable spec
```

## Why this README looks AI-generated?

Because it is lmao

## License

[MIT](LICENSE).
