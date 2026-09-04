<h1 align="center">multi</h1>

<p align="center"><a href="README.ru.md">[🇷🇺 →]</a> · <a href="README.zh.md">[🇨🇳 →]</a> </p>

<p align="center">run <code>multi</code>ple ai models for one task - code-review, planning, questions - and get <code>multi</code>ple opinions.</p>

***

<h2 align="center">what's this about?</h3>

`multi` runs one task through several AIs at once — code review, "is it actually done", [adhd](https://github.com/UditAkhourii/adhd) planning, or just a question — and shows you where the models converge and where they split. you judge, not them.

currently supports:
- claude subagents
- codex
- opencode
- gemini
- headless claude code with any API key or base URL you provide (e.g. [openrouter api key](https://openrouter.ai/), [9router url](https://9router.com/), etc)

<h2 align="center">what's the point?</h2>

one model planning, doing and reviewing work is not good. by using `multi`ple models you can get something truly valuable - differing opinions.  
three LLMs can find 5 bugs but only one will find 6th - and that's why you **need** to use `multi`. dont take my word fot it tho - check [evals](#evals) urself!   

best combo i found to myself is `Codex 5.6-sol` + `OpenCode Go` with `Qwen3.8-flash` and OpenRouter key with `GLM5.3-flash`, but you do you - you can use free models from OpenCode, OpenRouter and basically anything that grants you ai api

<h2 align="center">code-review</h2>

the main thing. what happens:

1. every backend + sub-agents from your profile reads the same snapshot of the code (not live tree so they cant break anything), in parallel.
2. a [ponytail](https://github.com/DietrichGebert/ponytail) lens hunts overengineering separately
3. one report: **corroborated** (two model families saw it), **single-source** (one saw it, checked against the code before it reaches you), **disagreed** (this is the part worth reading), **dropped** (with the reason, nothing vanishes silently)

knobs, all optional, all in words:

| knob | values | what it changes |
|---|---|---|
| target | a diff, a branch, files, a function, "what we just did" | what everyone reads |
| profile | any name from your `config.toml`, or "only codex and glm" | *who* reviews from outside |
| depth | `lite` / `normal` / `ultra` | how many claude angles: correctness only / + security + design / + did-the-task-actually-get-done, adversarial second codex pass, and a verify agent per single-source finding |
| model | `haiku` / `sonnet` / `opus` / `fable` | the claude sub-agents' model. depth never raises it on its own |
| effort | `low` … `max` | reasoning effort for the external models |
| `loop` | say it | fix, re-review, repeat until clean or 3 rounds. the only mode that edits your tree |

no `--backend`, no flags to remember - say "review this branch, ultra, profile free" and it does that. a backend that can't run shows up as `FAILED: <why>` in the report, never as silence. no non-claude reviewer configured at all = it refuses, because a one-model review wearing a multi-model label is worse than none.

<h2 align="center">other commands</h2>

| command | what it does |
|---|---|
| `/multi:check-if-done` | the "no bro is it REALLY done" one. a model that just wrote the code is the worst judge of whether it works, so this asks models that didn't write it, and refuses to call anything done without actually running a command that proves it. should fix "looks done but not really done sorry lmao" cases |
| `/multi:ask` | one question to everyone, one answer per model, side by side. no merging, no judging |
| `/multi:adhd` | summons every model with the [adhd](https://github.com/UditAkhourii/adhd) skill, a different cognitive frame per model. like mega-cool-planning mode |
| `/multi:setup` | tells you what this plugin is about, connects the backends, shows you your config |

<h2 align="center">install</h3>

```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

or
npx skills add szarkans/multi

or
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

then restart claude code and use `/multi:setup`

<h2 align="center">configure</h3>

once you ran `/multi:setup`, two files will be created: `~/.claude/multi/config.toml` - who reviews, which models, in what order, and what runs by default and `~/.claude/multi/providers.env` - api keys for you providers if you have any

a backend is a name + a type. four types: `codex`, `opencode`, `claude-headless` (claude code pointed at any anthropic-compatible endpoint: openrouter, 9router/omnirouter, local models, whatever you want) and `gemini`. want two endpoints? two `claude-headless` tables. a profile is who runs together.

<details>

<summary>💎 my `multi` profile</summary>

```toml
default_profile = "normal"

[backends.codex]
type = "codex"

[backends.opencode]
type = "opencode"

[backends.glm]                           # z.ai, with its own key
type = "claude-headless"
base_url = "https://api.z.ai/api/anthropic"
models = ["GLM-5.3-Flash"]
api_key_env = "ZAI_API_KEY"

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["qwen/qwen3.8-flash", "deepseek/deepseek-v4-flash-0731"]   # tried in order

[profiles]
normal = ["codex", "glm", "openrouter"]
free   = ["openrouter:openrouter/free", "codex"]   # name:model = exactly that model, no fallback
```

</details>

<details>
<summary>⭐️ the 'ion have any money' profile</summary>

completely free of charge usage of multiple models!

```toml
default_profile = "normal"

[backends.codex]
type = "codex"    # Free or Go plan

[backends.opencode]
type = "opencode"    # no `models` = using free models

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["openrouter/free"]           # router for free models

[profiles]
normal = ["codex", "opencode", "openrouter"]
```

</details>

no config file = built-in default (codex + opencode + openrouter). "review this with profile free" or "only codex and glm" works in chat, the agent passes it as `--backend`. profile is *who* reviews; how deep (lite / normal / ultra) is a separate knob and doesn't change.

every type and every field with comments: [`config.example.toml`](config.example.toml). needs `python3`.

<h2 align="center">why your README written like that?</h3>

Because it was written by me, human. *Mostly*.  
I'm really tired of b2b-ai-saas-skills-loop-code readme's.

<h2 align="center">evals</h3>

TBA.
