<h1 align="center">multi</h1>

<p align="center"><a href="README.ru.md">[🇷🇺 →]</a> · <a href="README.zh.md">[🇨🇳 →]</a> </p>

<p align="center">run <code>multi</code>ple ai models for one task - code-review, planning, questions - and get <code>multi</code>ple opinions.</p>

---

<h2 align="center">what's this about?</h3>

`multi` runs one task through several AIs at once — best for code review ([measured: it finds more bugs than the built-in code review](#evals)).
it also does "is it actually done", [adhd](https://github.com/UditAkhourii/adhd) planning, or just a question — and shows you where the models converge and where they split. you judge, not them.

currently supports as `multi`-backends:

- claude subagents
- codex
- opencode
- kilo code (free models, no login)
- gemini
- github copilot
- headless claude code with any API key or base URL you provide (e.g. GLM/DeepSeek/Qwen/[openrouter](https://openrouter.ai/) api key, [9router url](https://9router.com/), anything with an anthropic-compatible endpoint)

<h2 align="center">what's the point?</h2>

one model planning, doing and reviewing work is not good. by using `multi`ple models you can get something truly valuable - differing opinions.  
three LLMs can find 5 bugs but only one will find 6th - and that's why you **need** to use `multi`. don't take my word for it tho - check [evals](#evals) urself!   

best combo i found for myself is the latest codex model + the latest chinese flash models, but you do you - you can use free models from OpenCode, OpenRouter and basically anything that gives you an ai api

<h2 align="center">is it expensive?</h2>

you decide! with `multi`'s profile system you can make whatever team you can afford on a budget.

you can use the `i on have any money` profile with free Codex + free OpenCode models (which are, for some reason, really powerful). free is better than nothing, eh?
```toml
default_profile = "normal"

[backends.codex]
type = "codex"    # Free or Go plan

[backends.opencode]
type = "opencode"    # no `models` = using free models

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["qwen/qwen3.8-27b:free", "nvidia/nemotron-3-ultra-550b-a55b:free", "stealth/another-stealth-model-alpha"]           # tried in order

[profiles]
normal = ["codex", "opencode", "openrouter"]
```

you can use paid models with Codex Plus/Pro, OpenCode Go/Zen, z.ai API, Qwen API and even OpenRouter:
```toml
default_profile = "normal"

[backends.codex]
type = "codex"

[backends.opencode]
type = "opencode"
models = ["opencode-go/kimi-k3", "opencode-go/deepseek-v4-pro"]   # opencode-go/ = Go sub, opencode/ = Zen pay-per-token

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

or even stick OmniRouter/9router to it!
```toml
default_profile = "normal"

[backends.omniroute]
type = "claude-headless"
base_url = "http://localhost:20128"    # root, no /v1 - claude code adds /v1/messages itself
models = ["auto"]                      # omniroute's built-in free combo
api_key_env = "OMNIROUTE_API_KEY"      # no key in omniroute? put any string, multi just needs one

[profiles]
normal = ["codex", "omniroute"]
```

<details>
<summary>🤡 or go full clown: every free model on the planet in one review</summary>

free lists as of 30.09.2026. i mean... why not?

```toml
default_profile = "clown"

[backends.codex]
type = "codex"

[backends.oc]                            # opencode free models, plus every openai-compatible free tier below:
type = "opencode"                        # free key from each, then `opencode auth login` or a provider in opencode.json

[backends.openrouter]                    # free key is enough for :free models
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["openrouter/free"]

[backends.glm]                           # z.ai: 4.7 flash is free, 5.3 flash is not
type = "claude-headless"
base_url = "https://api.z.ai/api/anthropic"
models = ["GLM-4.7-Flash"]
api_key_env = "ZAI_API_KEY"

[backends.gemini]                        # google ai studio free tier
type = "gemini"
models = ["gemini-3.8-flash"]

[profiles]
clown = [
  "codex", "glm", "gemini",
  # opencode
  "oc:opencode/big-pickle", "oc:opencode/longcat-2.5-preview-free", "oc:opencode/mimo-v2.6-flash-free",
  "oc:opencode/muse-spark-1.3-contributor-free", "oc:opencode/space-bunny-free",
  # openrouter
  "openrouter:cohere/north-mini-code:free", "openrouter:dots-studio/dots-3-note-preview:free",
  "openrouter:google/gemma-4-26b-a4b-it:free", "openrouter:google/gemma-4-31b-it:free",
  "openrouter:inclusionai/ling-3.0-flash-sante:free", "openrouter:liquid/lfm-2.5-2.6b:free",
  "openrouter:nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "openrouter:nvidia/nemotron-3-super-120b-a12b:free",
  "openrouter:nvidia/nemotron-3-ultra-550b-a55b:free", "openrouter:nvidia/nemotron-3.5-lightning:free",
  "openrouter:poolside/laguna-s-2.1:free", "openrouter:poolside/laguna-xs-2.1:free",
  "openrouter:qwen/qwen3.8-27b:free", "openrouter:stealth/space-bunny-alpha",
  "openrouter:thinkingmachines/inkling-small:free", "openrouter:thinkingmachines/inkling:free",
  "openrouter:typesafe/jev-latest",      # a classifier. reviews your code with one enum
  "openrouter:openrouter/free",
  # nvidia nim - frontier chinese for free, if you get through the queue
  "oc:nvidia/moonshotai/kimi-k3", "oc:nvidia/z-ai/glm-5.3", "oc:nvidia/z-ai/glm-5.3-flash",
  # orcarouter
  "oc:orcarouter/deepseek-v4-pro", "oc:orcarouter/deepseek-v4-flash", "oc:orcarouter/qwen3.8-27b",
  "oc:orcarouter/hy3", "oc:orcarouter/orcarouter/free",
  # groq
  "oc:groq/groq/compound", "oc:groq/groq/compound-mini", "oc:groq/llama-3.1-8b-instant",
  "oc:groq/llama-3.3-70b-versatile", "oc:groq/openai/gpt-oss-120b", "oc:groq/openai/gpt-oss-20b",
  "oc:groq/qwen/qwen3.6-27b", "oc:groq/qwen/qwen3.8-27b", "oc:groq/allam-2-7b",
  # cerebras ($5 trial now, close enough)
  "oc:cerebras/gpt-oss-120b", "oc:cerebras/qwen-3.8-27b",
  # mistral (phone verification, they train on it)
  "oc:mistral/mistral-large-latest", "oc:mistral/codestral-latest", "oc:mistral/mistral-nemo",
  # cohere (1000 requests a month, this review eats one)
  "oc:cohere/command-r-plus", "oc:cohere/command-r",
  # cloudflare workers ai
  "oc:cloudflare-workers-ai/@cf/openai/gpt-oss-120b", "oc:cloudflare-workers-ai/@cf/meta/llama-4-scout-17b-16e-instruct",
  # ovhcloud (no key at all, 12 rpm)
  "oc:ovhcloud/gpt-oss-120b", "oc:ovhcloud/Qwen3-32B",
  # modelscope
  "oc:modelscope/Qwen/Qwen3.8-27B", "oc:modelscope/ZhipuAI/GLM-5.3-Flash",
  # the long tail
  "oc:kilo/nvidia/nemotron-3-ultra:free", "oc:llm7/deepseek-r1", "oc:bazaarlink/auto:free",
  "oc:aion/aion-2.5", "oc:agnes/agnes-2.0-flash", "oc:nscale/meta-llama/Llama-3.3-70B-Instruct",
  "oc:nscale/deepseek-ai/DeepSeek-R1-Distill-Llama-70B", "oc:together/ternary-bonsai-27b",
]
```

</details>

no config file = built-in default (codex + opencode + openrouter). "review this with profile free" or "only codex and glm" works in chat, the agent passes it as `--backend`. profile is *who* reviews; how deep (lite / normal / ultra) is a separate knob and doesn't change.

every type and every field with comments: [`config.example.toml`](config.example.toml). needs `python3`.

<h2 align="center">code-review</h2>

the main thing. what happens:

1. every backend and sub-agent from your profile reads the same snapshot of the code (not the live tree, so they can't break anything), in parallel.
2. a [ponytail](https://github.com/DietrichGebert/ponytail) lens hunts overengineering separately
3. one report: **corroborated** (two model families saw it), **single-source** (one saw it, checked against the code before it reaches you), **disagreed** (this is the part worth reading), **dropped** (with the reason, nothing vanishes silently)

knobs, all optional, all in words:


| knob    | values                                                    | what it changes                                                                                                                                                                |
| ------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| target  | a diff, a branch, files, a function, "what we just did"   | what everyone reads                                                                                                                                                            |
| profile | any name from your `config.toml`, or "only codex and glm" | *who* reviews from outside                                                                                                                                                     |
| depth   | `lite` / `normal` / `ultra`                               | how many claude angles: correctness only / + security + design / + did-the-task-actually-get-done, adversarial second codex pass, and a verify agent per single-source finding |
| model   | `haiku` / `sonnet` / `opus` / `fable`                     | the claude sub-agents' model. depth never raises it on its own                                                                                                                 |
| effort  | `low` … `max`                                             | reasoning effort for the external models                                                                                                                                       |
| `loop`  | say it                                                    | fix, re-review, repeat until clean or 3 rounds. the only mode that edits your tree                                                                                             |


no `--backend`, no flags to remember - say "review this branch, ultra, profile free" and it does that. a backend that can't run shows up as `FAILED: <why>` in the report, never as silence. no non-claude reviewer configured at all = it refuses, because a one-model review wearing a multi-model label is worse than none.

<h2 align="center">other commands</h2>


| command                | what it does                                                                                                                                                                                                                                                                                             |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/multi:check-if-done` | the "no bro is it REALLY done" one. a model that just wrote the code is the worst judge of whether it works, so this asks models that didn't write it, and refuses to call anything done without actually running a command that proves it. should fix "looks done but not really done sorry lmao" cases |
| `/multi:ask`           | one question to everyone, one answer per model, side by side. no merging, no judging                                                                                                                                                                                                                     |
| `/multi:skill`         | run any skill you have on every model at once. same prepared copy for everyone, all read-only, answers side by side.                                                                                                                                                                                     |
| `/multi:adhd`          | summons every model with the [adhd](https://github.com/UditAkhourii/adhd) skill, a different cognitive frame per model. like mega-cool-planning mode                                                                                                                                                     |
| `/multi:setup`         | tells you what this plugin is about, connects the backends, shows you your config                                                                                                                                                                                                                        |


<h2 align="center">install</h3>

claude
```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills
```

codex cli
```bash
codex plugin marketplace add szarkans/multi
codex plugin add multi@szkills
```

<h3 align="center">other hosts</h3>

just ask your agent to do this lmao:

```
Fetch and follow instructions from https://raw.githubusercontent.com/szarkans/multi/main/INSTALL.md
```

then run `/multi:setup` or `$multi:setup` or however your harness registers commands.

<h2 align="center">configure</h3>

once you run `/multi:setup`, two files will be created: `~/.config/multi/config.toml` - who reviews, which models, in what order, and what runs by default and `~/.config/multi/providers.env` - api keys for your providers if you have any. 

a backend is a name + a type. five types: `codex`, `opencode`, `kilo` (the Kilo Code CLI, an opencode fork: `type = "kilo"`, no `models` = a free one, not in the built-in config; setup adds it), `claude-headless` (claude code as the harness for an API. might switch to opencode or vercel-fx in the future, since claude code is bulky) and `gemini`. want two endpoints? two `claude-headless` tables. a profile is who runs together.

<h2 align="center">evals</h3>

tldr: `multi` found more at about the same cost, but obviously takes longer. and those aren't even the best models i could put in its profile!


|                                           | built-in `/code-review high` | `/multi:code-review normal` |
| ----------------------------------------- | ---------------------------- | --------------------------- |
| real bugs found                           | 14                           | **29**                      |
| ...that only this one found               | 1                            | **16**                      |
| minor stuff (wrong message, extra wait)   | 26                           | 58                          |
| findings that were just wrong             | 23%                          | 22%                         |
| "not a bug" (missing test, stale comment) | 21%                          | 22%                         |
| the one known bug per case (of 12)        | 7                            | 7                           |
| claude usage per case                     | \~$3.4                       | \~$3.5                      |
| time per case                             | \~10 min                     | \~19 min                    |


the bugs only `multi` caught: a secret written into prod logs, a temporary API error that drops a file forever, a failed request that deletes a user's permissions with no rollback. that kind of thing.

<details>
<summary>earlier run, 8 bugs, only the known bug counted</summary>

8 real bugs from my own projects. built-in `/code-review` found 3, `multi` found 6. same bugs, same checkout, both on sonnet.


|                      | built-in `/code-review high` | `/multi:code-review normal` |
| -------------------- | ---------------------------- | --------------------------- |
| bugs found (of 8)    | 3                            | **6**                       |
| claude usage per bug | \~$4                         | \~$5.6                      |
| time per bug         | \~11 min                     | \~26 min                    |


the extra models (codex, openrouter, glm) cost about $0.04 per bug. the difference is claude time, not them.
</details>

how it's measured:

- bugs are real, from my repos, each one proven: revert the fix → its own test fails. no toy snippets
- the reviewer sees the commit where the bug was born, like a PR. no fix, no hints in the tree
- grading is blind: another model gets a plain list of findings, doesn't know which tool wrote it, and checks it against the known bug. 3 times, majority wins
- every finding was checked against the code: codex and a free openrouter model labelled them blind, then opus read the code itself and made the final call, then sorted each one into bug / minor / not a bug. duplicates merged, nobody knew which tool wrote what

everything, including all the ways these numbers could be lying: [evals/RESULTS.md](evals/RESULTS.md)

<h2 align="center">why your README written like that?</h3>

Because it was written by me, human. *Mostly*.  
I'm really tired of b2b-ai-saas-skills-loop-code READMEs.
