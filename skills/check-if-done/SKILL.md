---
name: check-if-done
description: >-
  Check whether the work is actually finished rather than finished-looking —
  what was promised versus what really runs. Several models compare the task
  against the code, and every completion claim has to survive a command that
  was actually executed. Use before calling something done, before a PR, at the
  end of a session, or on "is this done", "did I finish", "check if done",
  "what did we skip".
allowed-tools: Bash, Read, Grep, Glob, Agent, TodoWrite
argument-hint: "[what was promised — a plan file, an issue, or nothing to use this session]"
---

# Check if it is actually done

!`sh -c 'for p in "$CLAUDE_PLUGIN_ROOT/scripts" "$HOME/.claude/skills/multi/scripts" "./.claude/skills/multi/scripts"; do [ -x "$p/probe.sh" ] && { "$p/probe.sh"; echo "scripts-dir: $p"; exit 0; }; done; echo "probe: NOT FOUND — locate scripts/probe.sh in this plugin and run it yourself"'`

A model that just wrote code is the worst possible judge of whether that code
works. It compares the task to its own summary of what it did, the two match,
and it says done. Nothing was verified — the check was a memory of an
intention.

So this skill does two things a normal review does not:

1. **Someone who did not write it looks at it** — Codex, OpenCode, and a
   sub-agent that has never seen this conversation.
2. **Nothing is called done without an executed command behind it.** Not "the
   tests should pass" — the command, its output, its exit code.

`$SCRIPTS` is whatever the probe printed as `scripts-dir:`.

## First: what was promised?

Everything here is a comparison, so you need both sides. In this order:

1. **What the user named** — a plan file, a spec, an issue, a PR description.
   Read it.
2. **This session** — what was asked for and what you said you did. Write it
   down as an explicit list before you go further; a promise you keep only in
   your head is one you will grade yourself on generously.
3. **Nothing?** Then say so and stop: *"nothing to check against — point me at
   a plan or tell me what this was supposed to do."* Do not substitute a code
   review. There is already a skill for that, and silently becoming it is how
   a completion check turns into theatre.

Then resolve the other side: what actually changed. `git diff`, the branch, the
files you touched. Say both out loud in one line before launching anything:

```
Promised: <where it came from — plan.md, the issue, what we did this session>
Changed:  <concrete paths or range>
```

## Launch the outside reviewers

They are free and slow to start, so they go first and run in the background
while you do the real work below.

Settle the allow-list first — this skill hands the outside reviewers a target
just like the review skill does, and an unfinished task lives in an untracked
working tree more often than not:

```bash
$SCRIPTS/safe-paths.sh [--diff <spec>] [--paths "<paths>"]
```

Describe only the allowed paths in the prompt below, and say in the report if
anything was withheld — a completion check that silently skipped part of the
change is the one failure this skill cannot afford.

```bash
cat > /tmp/multi-done-prompt.md <<'EOF'
<the promise, as a concrete list of what was supposed to end up working>

<what actually changed: paths, or the diff range and how to see it>
EOF

$SCRIPTS/ask.sh --question-file /tmp/multi-done-prompt.md \
                --out-prefix /tmp/multi-done \
                --model <from probe> [--fallback <from probe>] --effort high
```

Append this to the prompt file, verbatim in spirit — it is what makes them
answer the right question:

> You are checking whether a task was actually finished, not whether the code
> is good. For each item promised: does the code really do it, end to end, or
> does it only look like it does? Name what is missing, what is half-done, and
> what was silently dropped. Read the actual code — do not trust any summary of
> it. Anchor every point to a file and line. If everything promised is really
> there, say so plainly.

Spawn the `execution` sub-agent at the same time, in the same message. Give it
the promise, the changed paths, and what you know about the task — it is the
only reviewer with access to intent, and without that context it will correctly
refuse to guess.

## Then run the checks yourself

This is the part that makes the skill worth anything. **For every claim that
something works, execute the thing that proves it and read the output.**

- Tests exist → run them. Not the whole suite if it is slow: the ones covering
  what changed.
- It is a CLI → invoke it, with real arguments.
- It is an endpoint → call it.
- It is a migration → run it against a scratch database.
- It writes to a database or a file → look at what landed, not at the code that
  was supposed to land it.
- Nothing runnable exists → say that. "No way to verify this" is a finding, and
  often the most important one.

Rules that keep this honest:

- **Fresh output only.** A test run from earlier in the session proves nothing
  about the code as it stands now.
- **Read the whole output, including the exit code.** A suite that prints
  `PASSED` and exits non-zero did not pass.
- **A check that cannot fail is not a check.** If it passes with the feature
  ripped out, it never tested the feature.
- **Never edit code to make a check pass** while running this skill. That is
  the one move that turns a completion check into a lie.

Do not ask permission to run tests, builds or a CLI in read-only ways — that is
the job. Do ask before anything that writes outside the working tree: real
migrations, deploys, calls to third-party services with side effects.

## Report

```
# ✅ Check-if-done — <what was promised> 
Checked by: Claude · execution · Codex · OpenCode <model>
<one line if a reviewer was missing or a check could not be run — point at `/multi:setup` to connect it>

## Verdict
DONE: yes | partially | no — <one sentence>

## ❌ Not done (<n>)
1. **<promised item>** — `path/file.py:120`
   <what is missing> — evidence: <the command you ran and what it actually said>

## 🟡 Half done (<m>)
- **<promised item>** — <what works, what does not> — `path/file.py:88`

## 🔍 Unverifiable (<k>)
- **<promised item>** — no runnable check exists for this. <What would be needed.>

## ✅ Verified working (<j>)
- **<promised item>** — `pytest tests/test_auth.py` → 12 passed, exit 0

## Reviewers disagreed (<d>)
- <where Codex and the sub-agent split, and your call after looking>
```

Rules for the report:

- **An item with no executed evidence never lands in "Verified working."** It
  goes to Unverifiable, however obviously correct it looks. That distinction is
  the entire point of this skill.
- **Quote what the command actually printed**, not your reading of it.
- Anything promised must appear in exactly one section. A promise that shows up
  nowhere is the failure this skill exists to catch — go find it.
- If the outside reviewers found nothing and every check passed, say `DONE: yes`
  plainly. That is a real answer, not a wasted run.

Then stop. Offer to fix what is open — do not start fixing unprompted, and
never in the same breath as the verdict.
