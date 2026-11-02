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

The harness decides how a skill is named. Same skills everywhere, one sigil
different:

| Harness      | You type                                  |
| ------------ | ----------------------------------------- |
| Claude Code  | `/multi:code-review`, `/multi:ask`, …      |
| Codex CLI    | `$multi:code-review`, `$multi:ask`, …      |
| OpenCode     | `@multi-code-review` or `/multi-code-review` |
| omp          | `/multi-code-review`, `/multi-ask`, …      |

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
`$multi:ask`, `$multi:skill`, `$multi:setup` — Codex has no custom slash
commands, so `$multi:<name>` from the skill list is the way in. Codex installs a copy: after a `git pull` of the
clone, run `codex plugin remove multi@szkills` and `codex plugin add
multi@szkills` again.

## omp

```bash
omp plugin link ~/.claude/skills/multi
```

or, from a marketplace, `omp plugin marketplace add szarkans/multi` and
`omp plugin install multi@szkills`. The clone's `package.json` declares the
extension that registers `/multi-code-review`, `/multi-ask`,
`/multi-check-if-done`, `/multi-adhd`, `/multi-skill` and `/multi-setup`; its
`skills/` and `agents/` are picked up from the same package. `omp plugin list`
shows `multi` once it is installed.

## OpenCode

List the clone's `harnesses/opencode` directory under `plugins` in
`~/.config/opencode/opencode.json` (create the file if it is missing, merge if
it exists), with the absolute path to the clone:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["/home/<you>/.claude/skills/multi/harnesses/opencode"]
}
```

Restart OpenCode. The plugin registers every multi skill as `@multi-code-review`,
`@multi-check-if-done`, `@multi-adhd`, `@multi-ask`, `@multi-skill`,
`@multi-setup` (readable by the model, so `@` mentions and its own choice both
work) and as `/multi-<name>` for the TUI. The names carry the `multi-` prefix, so
another `code-review` skill on the machine does not collide with this one.

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

It prints `scripts-dir:`, the harness it thinks it is in (`host:`), the config
in use, and one line per backend. `codex:
OK` plus at least one other reviewer means reviews can run. Anything
`NOT CONFIGURED` or `MISSING` is for the person to fix through the setup skill;
tell them what the probe said. `host: unknown` only means no environment marker
and no matching parent process was found — the skills still work, they just name
every harness instead of theirs. Config lives in
`${XDG_CONFIG_HOME:-~/.config}/multi`, and the probe says so if an older
`~/.claude/multi` is still there.
