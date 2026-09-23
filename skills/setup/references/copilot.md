# GitHub Copilot CLI — another reviewer

1. Install GitHub Copilot CLI using the [official instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli). The probe says whether `copilot` is on `PATH`.
2. If it has not been authenticated, run `copilot login` in your own terminal. No API key belongs in `providers.env`.
3. Add `"copilot"` to a profile in `config.toml`, or select it for one run with `--backend copilot`.

The built-in config already defines `[backends.copilot]`, but leaves it out of the default profile because each call spends GitHub AI credits. In a custom config add:

```toml
[backends.copilot]
type = "copilot"
models = []       # Auto; required on Copilot Student
timeout = 600
```

`models = []` asks Copilot to choose and the answer names the model used when the CLI reports it (otherwise `unknown`). On plans that allow manual model selection, put **one** CLI model ID in `models`, or pin a run with `copilot:<model>`. Copilot Student supports Auto only; a named model may be rejected even if it appears in GitHub's model catalogue. `copilot --help` gives the current flags, and `/model` inside an interactive Copilot session shows models available to this account.

Copilot rejects `--reasoning-effort` with Auto, so multi lets Copilot choose the effort there. With a named model, multi sends non-default `--effort`; a model without configurable reasoning may reject that combination.

The runner allows only `view`, `grep`, and `glob`, disables repository instructions and built-in MCP, and runs on the isolated review copy. A direct `ask.sh` call in a checkout with project hook settings is refused; make a snapshot first. The probe and `setup.sh status` can confirm that the CLI exists, but cannot check login or remaining credits without a billed model call. A failed call appears with its reason in the backend's `.dead` marker and diagnostics next to it.
