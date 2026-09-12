# Installing multi

You are an agent reading this because a person asked you to install multi.
Work out which harness you are, do that section only, then run the check at
the end. Do not do the other sections.

One clone serves every harness on the machine. If it is not there yet:

```bash
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

Everything below assumes that path. A different path is fine, use it
consistently.

## Claude Code

Skip the clone. Either of:

```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills
```

or `npx skills add szarkans/multi`, or the clone above on its own. Restart
Claude Code, then run `/multi:setup`.

## Codex CLI or Codex app

```bash
codex plugin marketplace add szarkans/multi
codex plugin add multi@szkills
```

Codex reads the repo's `.claude-plugin/marketplace.json` as the marketplace. Skills appear as `$multi:code-review`, `$multi:check-if-done`, `$multi:adhd`,
`$multi:ask`, `$multi:setup`. Codex installs a copy: after a `git pull` of the
clone, run `codex plugin remove multi@szkills` and `codex plugin add
multi@szkills` again.

## OpenCode

Add the clone's `skills` directory to `skills.paths` in the global
`~/.config/opencode/opencode.json` (create the file if it is missing, merge if
it exists):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "skills": {
    "paths": ["~/.claude/skills/multi/skills"]
  }
}
```

Restart OpenCode. The `skill` tool then lists `code-review`, `check-if-done`,
`adhd`, `ask`, `setup`. Skills are named by their frontmatter `name`, so
another `code-review` skill on the machine collides with this one; if that
happens, say so to the person.

## Gemini CLI

```bash
gemini extensions install https://github.com/szarkans/multi
```

Gemini activates a skill itself when the request matches it.

## Any other harness that reads SKILL.md

Point it at `~/.claude/skills/multi/skills` the way it takes a skills
directory (a config entry, or one symlink per skill into `~/.agents/skills`).
Every SKILL.md in there says what to run first.

## Check

Run the probe from the clone:

```bash
~/.claude/skills/multi/scripts/probe.sh
```

It prints `scripts-dir:`, the config in use, and one line per backend. `codex:
OK` plus at least one other reviewer means reviews can run. Anything
`NOT CONFIGURED` or `MISSING` is for the person to fix through `multi:setup`;
tell them what the probe said. Config lives in
`${XDG_CONFIG_HOME:-~/.config}/multi`, and the probe says so if an older
`~/.claude/multi` is still there.
