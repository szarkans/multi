<h1 align="center">multi</h1>

<p align="center"><a href="README.ru.md">[🇷🇺 →]</a> · <a href="README.zh.md">[🇨🇳 →]</a></p>

<p align="center">one code review, several AI models. including free ones.</p>

---

one model misses things. another model may notice them. `multi` puts independent reviewers on the same code, checks what they found, and gives you one report — including the disagreements.

**it found 29 real bugs where the built-in Claude Code review found 14.** in our 16-case evaluation, with similar Claude usage and roughly twice the wall time. [see the results and how we measured them](evals/RESULTS.md).

you don't need a team of expensive models. add free reviewers from OpenCode or OpenRouter to the models you already use. even a free opinion is useful when it catches something the others missed.

> [!TIP]
> for simplicity reason ill use claude code type command (e.g. `/multi:setup`) but you can use whatever your harness supports - `$multi` in Codex, `@multi` in opencode and etc

<h2 align="center">install & run</h2>

**lazy ass**

```md
hey can you install https://github.com/szarkans/multi and set up it and like tell me how it works and how to use it most efficiently
```

**claude code**

```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills
```

**codex cli**

```bash
codex plugin marketplace add szarkans/multi
codex plugin add multi@szkills
```

restart the host, then run `/multi:setup`. the setup skill checks your installed CLIs, creates the config and helps connect reviewers.

then ask:

```text
/multi:code-review review my last changes
/multi:code-review review this branch, ultra
/multi:code-review review auth.py, profile free
```

<h2 align="center">add free reviewers</h2>

OpenCode has free models as well as OpenRouter! this is a minimal `~/.config/multi/config.toml`:

```toml
default_profile = "free"

[backends.opencode]
type = "opencode"                 # no models = auto-pick a free OpenCode model

[backends.openrouter]
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["openrouter/nemotron-giga-ultra-mega", "openrouter/stealth-alpha-bunny-ox-alpha-crossaint"]     # put any free model that available rn

[profiles]
free = ["opencode", "openrouter"]
```

run `/multi:setup` to connect the CLIs and OpenRouter key. keys go in `~/.config/multi/providers.env`. `claude-headless` uses the Claude CLI as a client for an Anthropic-compatible endpoint; it doesn't mean the reviewer itself is Claude.

<h3 align="center">is this actually better?</h3>  
our tests say different models do find different defects. in an earlier controlled comparison, a cheap OpenRouter reviewer independently flagged a real issue alongside other reviewers. in the larger 16-case comparison, `multi` found 29 bugs against 14 for the built-in review.

those 29-vs-14 numbers **are not a free-only benchmark**: that run used Claude, Codex and GLM. it's evidence for multi-model review, not a promise that every free lineup doubles your results. [read the methodology](evals/RESULTS.md). also: free services may be slower, rate-limited, or use prompts for training. check their policies before sending private code.

<h2 align="center">what you`ll have</h2>

| command | what it does |
| --- | --- |
| `code-review` | independent reviews of a diff, branch, file, function or repo, reconciled into one report |
| `check-if-done` | compares the original task with the code and requires executed proof before calling it done |
| `ask` | one question to several models; answers shown side by side, no judge |
| `skill` | runs an installed skill through several models, side by side |
| `adhd` | divergent planning with different models and cognitive frames; based on [adhd](https://github.com/UditAkhourii/adhd) |
| `setup` | detects available reviewers and helps configure them |

reviewers see a snapshot, not your working tree. reports separate **corroborated**, **single-source**, **disagreed** and **dropped** findings. failed backends are shown, not silently ignored. say `loop` to fix and re-review (up to three rounds); that's the mode that changes your working tree.

### review controls

| say this | effect |
| --- | --- |
| `review this branch` | target: diff, branch, files, function, or whatever you name |
| `profile free` | who reviews; any profile in your config |
| `lite` / `normal` / `ultra` | review depth, independent of the chosen profile |
| `effort high` | reasoning effort for external reviewers that support it |
| `loop` | fix → review again, up to three rounds |
| `no-train` | excludes reviewers without a `no training` verdict for that run |

<h2 align="center">config reference (every key)</h2>

there are two files, by design:

- `~/.config/multi/config.toml` — models, endpoints, profiles, timeouts and rules.
- `~/.config/multi/providers.env` — provider keys. the setup helper can write them without echoing secrets.

**global options**

| key | meaning |
| --- | --- |
| `default_profile` | profile used when you don't choose one explicitly |
| `verbose_prompt` | show the complete prompt for each reviewer before sending; default `false` |
| `no_train` | use only models marked as not training on your data; default `false` |

**backend options** — add as many `[backends.name]` sections as you like.

| key | meaning |
| --- | --- |
| `type` | `codex`, `opencode`, `kilo`, `claude-headless`, `gemini` or `agy` |
| `models` | ordered fallback list; empty or omitted uses the backend's default; Codex, Gemini and agy allow at most one |
| `base_url` | Anthropic-compatible endpoint for `claude-headless` |
| `api_key_env` | environment variable containing this backend's key; defaults to `<BACKEND_NAME>_API_KEY` |
| `timeout` | seconds allowed for the backend to complete |
| `stall` | seconds of silence before a supported backend is considered stuck |
| `trains` | override this account's training verdict: `true` or `false`; does not change provider settings |
| `effort` | per-model reasoning effort, e.g. `{ "model-id" = "low" }` |
| `avoid` | UTC time windows when this backend should not run, e.g. `["Mon-Fri 01:00-04:00 UTC"]`. for backends like deepsek api with peak/offpeak hours pricing |

**profiles** decide who reviews, not how deeply:

```toml
[profiles]
free    = ["opencode", "openrouter:openrouter/free"]
regular = ["codex", "opencode"]
```

`opencode` means one reviewer that tries its `models` list in order until one works. `openrouter:openrouter/free` pins that exact model/router, with no fallback. repeat an entry to run it more than once. select a profile in plain English, or pass a one-off backend list; `all` selects every configured backend.

supported backends include Codex CLI, OpenCode, Kilo Code, Gemini CLI, Antigravity (`agy`), and arbitrary Anthropic-compatible endpoints through `claude-headless` (OpenRouter, z.ai, DeepSeek, local routers and others). some need installed CLIs, logins or keys.

**[config.example.toml](config.example.toml) contains every field with real examples**, including free, paid, local and mixed profiles. [providers.example.env](providers.example.env) shows the key names. the example config is the place to copy from; this page is the map.

<h2 align="center">the numbers, without the pitch</h2>

on 16 real bug-introducing commits, against Claude Code's built-in `/code-review`:

| | built-in | `multi` |
| --- | ---: | ---: |
| real bugs found | 14 | **29** |
| false findings | 23% | 22% |
| median Claude usage per case | ~$3.4 | ~$3.5 |
| median time per case | ~10 min | ~19 min |

same code, different review pipelines. findings were labelled blind and checked against the code; the final severity classification used a model judge. it was a small experiment, not an independent human audit, and the known planted-bug score was tied at 7/12.

we keep the failure cases, grading rules and limitations in [evals/RESULTS.md](evals/RESULTS.md). read it before trusting the numbers. that's why it's there.

---

*hey! you read the whole thing? thanks <3*
