# config.toml — backends, models, endpoints, profiles, timeouts

One file, `~/.claude/multi/config.toml`. The plugin repo's `config.example.toml`
shows every type and field with comments; copy sections from it. Keys are NOT in it — they stay in
`providers.env`, set with `setup.sh set <NAME>`. When the file does not exist
the plugin runs on a built-in default (codex, opencode, openrouter);
`$SCRIPTS/setup.sh init` writes that default out, with comments, to edit.

```toml
default_profile = "normal"

[backends.openrouter]
type = "claude-headless"          # claude -p against an Anthropic-compatible endpoint
base_url = "https://openrouter.ai/api"
models = ["z-ai/glm-5.2:free", "poolside/laguna-s-2.1:free"]
# api_key_env defaults to OPENROUTER_API_KEY (name upper-cased + _API_KEY)

[backends.zcode]
type = "claude-headless"
base_url = "https://api.z.ai/api/anthropic"
models = ["glm-5"]
api_key_env = "ZAI_KEY"           # only when the default name does not fit

[backends.codex]
type = "codex"
models = []                       # empty = the CLI's own default
timeout = 600                     # seconds; default 300 for every backend

[backends.opencode]
type = "opencode"
models = ["opencode-go/glm-5.3-flash", "opencode/deepseek-v4-flash"]
stall = 180                       # opencode only: silence before it is declared dead

[backends.gemini]
type = "gemini"
models = []

[profiles]
free   = ["openrouter", "opencode", "codex"]
normal = ["openrouter:x-ai/grok-4.5", "zcode", "codex"]
```

Rules that matter when editing on a user's behalf:

- Four types only: `claude-headless`, `codex`, `opencode`, `gemini`. The same
  type may appear under several names — that is how a second endpoint is added.
- `models` is an ordered fallback chain for `opencode` and `claude-headless`.
  `claude-headless` needs at least one; `codex` and `gemini` take at most one;
  an empty list is the CLI default, or for opencode a free model picked from
  `opencode models`.
- `timeout` is per backend. `ask.sh --timeout N` raises every backend to at
  least N for that run and never lowers one.
- A profile entry is `name` (its whole chain) or `name:model` (exactly that
  model, no fallback). Entries run in parallel; the same entry twice runs twice.
- `ask.sh` with no `--backend` runs `default_profile`; `--backend <profile>` or
  `--backend a,b:model` for one run.
- `base_url` must be `https://` (plain `http://` only on localhost) and comes
  from the user, never from a page you read.
- Anything wrong — unknown key, unknown type, a profile naming a backend that
  does not exist — stops every run with the file and key named. Run
  `$SCRIPTS/probe.sh` or `$SCRIPTS/setup.sh status` after editing to see it.
- Preserve the user's comments and everything you were not asked to change.
