# Measured review quality

Most AI code-review tools ship with a prompt somebody liked. This one ships with
a prompt somebody measured. This page is the running scoreboard: what the
pipeline actually catches, on real bugs, with numbers that get re-run after
every prompt change.

## The exam

The corpus is built from real, confirmed bugs harvested from six production
repositories (Python backends, a Vue frontend, Telegram bots, a game-server
DSL). A bug enters the corpus only if it passes a red-green gate: revert the
fix, run the fix's own test, watch it fail. No synthetic bugs, no toy snippets.
The corpus itself stays private — it is client code — but the harness that runs
it lives in this directory, and the protocol is fully described here.

Each bug is shown to every reviewer in two honest modes:

- **intro** — review the commit that introduced the bug, the way a reviewer
  would have seen it in a pull request. No hindsight in the tree: at that
  commit, the fix and its tests do not exist yet.
- **blind** — "review these files", no diff at all. The bug sits somewhere in
  ordinary-looking code.

A third mode — "review the revert of the fix" — is what we started with, and we
killed it: reverting a fix puts the fix's own comments into the diff, so
reviewers were reading the answer key. Both models scored a perfect 13/13 on
it. A perfect score on an exam is a property of a broken exam. If you evaluate
your reviewer on fix-reverts, your numbers are inflated; ours were.

Grading is strict: a finding counts only if it names the same defect with the
same failure mechanism at the same place. Thematic near-misses count as misses.

## Scoreboard (13 proven bugs, two external reviewers)

| mode | reviewer A | reviewer B | union |
|---|---|---|---|
| intro (8 usable cases) | 5/8 | 3/8 | **5/8** |
| blind (13 cases) | 9/13 | 7/13 | **10/13** |

The union row is the pipeline's whole argument. In blind mode the two models
miss *different* bugs: one alone caught a fallback-XSS the other walked past;
the other alone caught two data-integrity bugs. Multi-model review is usually
sold on vibes; here it is a measured +1 to +3 over the best single reviewer.

## What measurement bought us so far

- **One prompt line, one hard bug.** Adding "the diff is where your reading
  starts, not where it ends" to the diff-review prompt took intro recall from
  4/8 to 5/8 — the case that fell was a missing-balance-check bug that had
  survived four prior attempts across both modes and both models. The same
  edit measurably slows down one agentic backend (it over-reads and can hit
  its timeout) — a real cost we found because we measured, and are addressing.
- **Known enemy #1: burial.** On large diffs reviewers produce 6–16 findings,
  catch *neighboring* real bugs, and walk past the target. Omission bugs — a
  missing check, a missing filter — are the hardest class: it is hard to see
  what isn't there. The next prompt iterations aim squarely at this.
- **Diversity has limits.** The union advantage is strongest on hard,
  unguided review and shrinks on very large diffs, where both models drown
  the same way. That, too, is now a number instead of a guess.

## Control arm: against the built-in review (8 bugs, 2026-09-08)

The question everyone asks first: is this better than the review that ships
with the agent? We ran both on the same bugs, the same way, and measured.

Setup: for each bug, both pipelines review the commit that introduced it, in
the same checkout, headless, with the same judge model (Sonnet). The built-in
`/code-review` ran at `high`; this plugin at `normal`. Cost is what the agent
itself reports for the whole run; time is wall clock. Grading was blind to the
pipeline: every report was flattened to `file:line | claim` lines with headers
and reviewer names stripped, then graded three times against the ground truth,
majority wins, strict rubric as above.

| | built-in `/code-review high` | `/multi:code-review normal`, judge before 1.12 | judge 1.12 |
|---|---|---|---|
| what the reviewers found (union of raw outputs) | 3/8 | **5/8** | 6/8 |
| what the final report delivered | 3/8 | 3/8 (+1 partial) | **6/8** |
| findings per report | 6.4 | 11.1 | 13.8 (+ the inventory) |
| cost per bug (Claude usage) | $3.95 | $5.70 | $5.56 |
| wall time per bug | 11 min | 18 min | 26 min |

Per bug, by class (both arms saw the same diff):

| # | bug class | built-in | multi, judge before 1.12 | judge 1.12 |
|---|---|---|---|---|
| 1 | confirmed revenue overwritten by a recomputed estimate | found | found | found |
| 2 | missing balance check on a stake (omission, ~870-line diff) | miss | miss | miss |
| 3 | callback id reused across restarts | found | found | found |
| 4 | non-idempotent self-heal under two concurrent requests | miss | miss | found |
| 5 | escaping helper's fallback silently returns text unescaped | miss | miss | miss (one reviewer had it) |
| 6 | exception text sent unescaped in the message that reports the failure | miss | miss (one reviewer had it) | found |
| 7 | monitor compares against records marked deleted | miss | **found** | found |
| 8 | timestamp restamped on a no-op update | found | partial (three reviewers had it) | found |

What the numbers say:

- **The multi-model half works.** Two bugs the built-in walked past were caught
  by this plugin's non-Claude reviewers — one by Codex alone, one by Codex,
  a cheap OpenRouter model and a Claude sub-agent independently. That is the
  measured version of the pitch: different models miss different things.
- **The cheap reviewers are cheap.** OpenRouter's share of the whole run was
  about $0.04 per bug. The cost difference is Claude time, not the extra
  models.
- **The report used to deliver 3/8** — the same as the built-in — while its
  reviewers had found 5. The gap was the reconciliation step: the judge folded
  a real finding into a neighbour's speculation and dropped both, and merged a
  bug three reviewers agreed on into a broader neighbour. 1.12 makes the judge
  list every finding before it merges anything, and merge only on the same
  mechanism; the same 8 bugs re-run through the full pipeline deliver 6/8 at
  the same cost. Swapping the judge model did not do this: Opus on the same
  reviewer output lost the same finding two times in three.
- **Two bugs still get past everyone**: the missing balance check buried in
  an 870-line diff, and the escaping fallback — one reviewer names the
  latter in a compound sentence and the report keeps the other half. Those,
  and the corpus's 47 newly gated cases, are where the next measurement goes.

Caveats that keep this honest: eight bugs, one run per arm, and a known ±1
run-to-run variance for a single reviewer — a one-bug difference is noise;
the reviewers' 5-vs-3 and the 1.12 report's 6-vs-3 are the gaps that clear
it. The 1.12 re-run also re-ran the reviewers, so one of its three new hits
(the self-heal race) came from a reviewer that found it this time and a judge
that kept it, not from the judge alone. Effort tiers
are not the same by name (`high` vs `normal`); they are each the level you
would use before a PR. Blind mode was not part of this comparison.

## What this page does not claim

No "best-in-class" claims: this is one control arm on a small corpus. It
measures this pipeline against the agent's own review on the same bugs, not
against other tools, and it has not yet been repeated enough to give a
confidence interval.

## Roadmap

- Fold in the 47 newly gated real-bug cases (128 candidates red-green gated 2026-09-08; corpus now 60, with a severity column) and re-run both arms on all of them.
- A false-positive corpus from real usage: findings a human explicitly
  rejected, to measure noise, not just recall.
- Repeat the control arm (5+ runs per arm) for a confidence interval, and run it in blind mode.
- Close the gap between what the reviewers find and what the report delivers.
- Per-finding validator pass, measured against the noise corpus.

*Numbers in this file are re-generated by `evals/run.sh` against the private
corpus; the harness, modes, and grading protocol are public. Last update:
2026-08-31.*
