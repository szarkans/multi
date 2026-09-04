#!/usr/bin/env python3
"""Read, validate and resolve the multi config — the one place backends live.

    config.py resolve [--backend SPEC] [--timeout N]   who runs, one line each
                      (--timeout N is a FLOOR: each backend gets max(N, its own))
    config.py backends                                  every configured backend
    config.py check                                     validate, say where it read
    config.py init                                      write the default file
    config.py path                                      where the file is

The file is $MULTI_HOME/config.toml ($MULTI_CONFIG overrides the path). When
it does not exist the built-in default below is used — the plugin works out of
the box, and `init` writes that default out so there is something to edit.

Why Python: bash cannot read TOML. Everything else stays in bash; this prints
tab-separated lines and ask.sh/probe.sh/setup.sh read them like any other
command's output. Keys are NOT here — they live in providers.env, sourced by
providers.sh; this file only names the variable a backend reads its key from.

Output of `resolve` (one participant per line, tab-separated):
    suffix  name  type  pinned  chain  base_url  api_key_env  timeout  stall
Empty fields print as "-" (a whitespace IFS in bash would swallow them).
`pinned` is the model named as backend:model — exactly that model, no
fallback. `chain` is the backend's own model list, space-separated, walked in
order when nothing is pinned. `suffix` is the answer-file suffix: name, or
name-2, name-3 for a repeated backend.
"""
import os
import re
import sys
from urllib.parse import urlsplit

try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_vendor"))
    import tomli as tomllib  # type: ignore

TYPES = ("claude-headless", "codex", "opencode", "gemini")
BACKEND_KEYS = {"type", "models", "base_url", "api_key_env", "timeout", "stall"}
TOP_KEYS = {"backends", "profiles", "default_profile"}
DEFAULT_TIMEOUT = 300
DEFAULT_STALL = 180

DEFAULT_TOML = """\
# multi — who answers when several models are asked the same thing.
#
# backends: named ways to run a model. Four types exist:
#   codex            the Codex CLI, read-only sandbox
#   opencode         the OpenCode CLI with the plugin's read-only agent
#   claude-headless  `claude -p` pointed at any Anthropic-compatible endpoint
#                    (OpenRouter, 9router, z.ai, Moonshot, a self-hosted router)
#   gemini           the Gemini CLI
# The same type may appear under several names — two claude-headless backends
# with different base_url and api_key_env are two different reviewers.
#
# models: ordered fallback chain, first entry preferred. An empty list means
# the CLI's own default (codex, gemini) or a free model picked from
# `opencode models` at run time (opencode). claude-headless needs at least one.
# Only opencode and claude-headless walk a chain today; codex and gemini take
# at most one model, and the config says so instead of ignoring the rest.
# base_url: claude-headless only.
# api_key_env: the variable in providers.env holding the key; defaults to
#   <NAME>_API_KEY, e.g. OPENROUTER_API_KEY. Set it with: setup.sh set <NAME>
# timeout: seconds per run, default 300. ask.sh --timeout N raises every
#   backend to at least N for that run (the review skill passes 2400) and never
#   lowers one. stall (opencode only): seconds of silence before the model is
#   declared dead, default 180.
#
# profiles: named lists of who runs, in parallel. An entry is a backend name
# (its whole chain) or backend:model (exactly that model, no fallback). The
# same entry twice runs twice. ask.sh --backend <profile> picks one;
# --backend a,b:model is a one-off profile; no --backend = default_profile.

default_profile = "default"

[backends.codex]
type = "codex"
models = []
timeout = 600            # codex is the slow one

[backends.opencode]
type = "opencode"
models = []              # empty = a free model from `opencode models`

[backends.openrouter]
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = [               # :free pools go 429 when busy; the runner walks the list
  "z-ai/glm-5.2:free",
  "poolside/laguna-s-2.1:free",
  "nvidia/nemotron-3-super-120b-a12b:free",
  "cohere/north-mini-code:free",
  "openai/gpt-oss-20b:free",
]

[backends.gemini]
type = "gemini"
models = []

[profiles]
default = ["codex", "opencode", "openrouter"]
"""


class ConfigError(Exception):
    pass


def config_path():
    if os.environ.get("MULTI_CONFIG"):
        return os.environ["MULTI_CONFIG"]
    home = os.environ.get("MULTI_HOME") or os.path.join(os.path.expanduser("~"), ".claude", "multi")
    return os.path.join(home, "config.toml")


def _positive_int(where, key, value):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ConfigError("%s: %s must be a positive integer, got %r" % (where, key, value))
    return value


def _str_list(where, key, value):
    # One word each: bash splits chains on whitespace, so a model "gpt 4"
    # would silently become two models.
    if not isinstance(value, list) or not all(isinstance(m, str) and re.match(r"^\S+$", m) for m in value):
        raise ConfigError("%s: %s must be a list of non-empty strings without whitespace" % (where, key))
    return list(value)


def load(path=None):
    """Return (config, source). source is the path read, or 'built-in default'."""
    path = path or config_path()
    if os.path.exists(path):
        try:
            with open(path, "rb") as f:
                raw = tomllib.load(f)
        except tomllib.TOMLDecodeError as e:
            raise ConfigError("%s: not valid TOML: %s" % (path, e))
        except OSError as e:
            raise ConfigError("%s: cannot read: %s" % (path, e.strerror or e))
        source = path
    else:
        raw = tomllib.loads(DEFAULT_TOML)
        source = "built-in default"
    return validate(raw, source), source


def validate(raw, where):
    unknown = set(raw) - TOP_KEYS
    if unknown:
        raise ConfigError("%s: unknown top-level key(s): %s" % (where, ", ".join(sorted(unknown))))
    backends_raw = raw.get("backends")
    if not isinstance(backends_raw, dict) or not backends_raw:
        raise ConfigError("%s: [backends.<name>] — at least one backend is required" % where)
    backends = {}
    for name, b in backends_raw.items():
        w = "%s: [backends.%s]" % (where, name)
        # The name becomes an answer-file suffix (<prefix>-<name>.txt) and a
        # --backend token: letters, digits, _ and - only, or a quoted key like
        # "../../x" walks out of the run directory.
        if not re.match(r"^[A-Za-z0-9_][A-Za-z0-9_-]*$", name):
            raise ConfigError("%s: backend names are letters, digits, _ and - only" % w)
        if not isinstance(b, dict):
            raise ConfigError("%s must be a table" % w)
        unknown = set(b) - BACKEND_KEYS
        if unknown:
            raise ConfigError("%s: unknown key(s): %s (allowed: %s)" % (w, ", ".join(sorted(unknown)), ", ".join(sorted(BACKEND_KEYS))))
        t = b.get("type")
        if t not in TYPES:
            raise ConfigError("%s: type must be one of %s, got %r" % (w, ", ".join(TYPES), t))
        models = _str_list(w, "models", b.get("models", []))
        base_url = b.get("base_url", "")
        if t == "claude-headless":
            if not models:
                raise ConfigError("%s: a claude-headless backend needs at least one model" % w)
            if not isinstance(base_url, str) or not base_url.strip():
                raise ConfigError("%s: a claude-headless backend needs base_url" % w)
            base_url = base_url.strip().rstrip("/")  # "…/api//" would request //v1/messages
            # The key goes to this host as a Bearer token, so plain http is only
            # for the loopback. Compare the parsed HOSTNAME, not a string prefix:
            # "http://localhost.evil.example" and "http://127.0.0.1@evil.example"
            # both start with the loopback text and neither is it.
            u = urlsplit(base_url)
            if u.scheme == "https" and u.hostname:
                pass
            elif u.scheme == "http" and u.hostname in ("localhost", "127.0.0.1", "::1") and not u.username:
                pass
            else:
                raise ConfigError("%s: base_url must be https:// (http:// only on localhost) — the API key is sent there as a Bearer token" % w)
        elif "base_url" in b:
            raise ConfigError("%s: base_url only applies to type = \"claude-headless\"" % w)
        if t in ("codex", "gemini") and len(models) > 1:
            raise ConfigError("%s: type %s takes at most one model — fallback chains are walked by opencode and claude-headless only, and the rest of this list would be silently ignored" % (w, t))
        if "stall" in b and t != "opencode":
            raise ConfigError("%s: stall only applies to type = \"opencode\"" % w)
        key_env = b.get("api_key_env", name.upper().replace("-", "_") + "_API_KEY")
        # It is expanded by name in bash (eval "key=\${$key_env:-}"), so it must
        # be a plain identifier — anything else is a shell injection waiting
        # for a pasted config.
        if not isinstance(key_env, str) or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key_env):
            raise ConfigError("%s: api_key_env must be a variable name (letters, digits, _), got %r" % (w, key_env))
        backends[name] = {
            "type": t,
            "models": models,
            "base_url": base_url,
            "api_key_env": key_env.strip(),
            "timeout": _positive_int(w, "timeout", b.get("timeout", DEFAULT_TIMEOUT)),
            "stall": _positive_int(w, "stall", b.get("stall", DEFAULT_STALL)),
        }
    profiles_raw = raw.get("profiles", {})
    if not isinstance(profiles_raw, dict):
        raise ConfigError("%s: [profiles] must be a table of lists" % where)
    profiles = {}
    for pname, entries in profiles_raw.items():
        w = "%s: profiles.%s" % (where, pname)
        if pname == "all":
            raise ConfigError("%s: 'all' is reserved (every configured backend)" % w)
        entries = _str_list(w, "entries", entries)
        if not entries:
            raise ConfigError("%s: a profile must name at least one backend" % w)
        for e in entries:
            bname = e.split(":", 1)[0]
            if bname not in backends:
                raise ConfigError("%s: entry %r names a backend that does not exist (have: %s)" % (w, e, ", ".join(backends)))
        if pname in backends:
            raise ConfigError("%s: a profile and a backend share the name %r — --backend %s would be ambiguous" % (w, pname, pname))
        profiles[pname] = entries
    default_profile = raw.get("default_profile")
    if default_profile is None:
        raise ConfigError("%s: default_profile is required" % where)
    if not isinstance(default_profile, str):
        raise ConfigError("%s: default_profile must be a string (a profile name)" % where)
    if default_profile not in profiles:
        raise ConfigError("%s: default_profile = %r names a profile that does not exist (have: %s)" % (where, default_profile, ", ".join(profiles) or "none"))
    return {"backends": backends, "profiles": profiles, "default_profile": default_profile}


def resolve(cfg, spec=None):
    """Turn a --backend spec into participants. Returns a list of dicts."""
    backends, profiles = cfg["backends"], cfg["profiles"]
    if spec is None or spec == "":
        entries = profiles[cfg["default_profile"]]
    elif spec in profiles:
        entries = profiles[spec]
    elif spec == "all":
        entries = list(backends)
    elif spec == "both":  # the historical default: the two CLIs; a user profile of that name wins
        entries = [n for n in ("codex", "opencode") if n in backends]
        if not entries:
            raise ConfigError("--backend both: neither codex nor opencode is configured")
    else:
        entries = [e.strip() for e in spec.split(",") if e.strip()]
        if not entries:
            raise ConfigError("--backend: empty")
    out, seen, used = [], {}, set()
    for e in entries:
        name, colon, model = e.partition(":")
        if name not in backends:
            raise ConfigError("--backend: unknown backend %r (backends: %s; profiles: %s; also all, both)"
                              % (name, ", ".join(backends), ", ".join(profiles) or "none"))
        if colon and not model:
            raise ConfigError("--backend: %r pins nothing — write %s:<model>, or bare %s for its chain" % (e, name, name))
        # Suffix = answer file name. Unique across the whole run, not just
        # per backend: ["foo", "foo", "foo-2"] must not write foo-2 twice.
        seen[name] = seen.get(name, 0) + 1
        suffix = name if seen[name] == 1 else "%s-%d" % (name, seen[name])
        while suffix in used:
            seen[name] += 1
            suffix = "%s-%d" % (name, seen[name])
        used.add(suffix)
        b = backends[name]
        out.append({
            "suffix": suffix, "name": name, "type": b["type"], "pinned": model,
            "chain": b["models"], "base_url": b["base_url"], "api_key_env": b["api_key_env"],
            "timeout": b["timeout"], "stall": b["stall"],
        })
    return out


def _line(*fields):
    for f in fields:
        if "\t" in str(f) or "\n" in str(f):
            raise ConfigError("a config value contains a tab or newline: %r" % f)
    print("\t".join(str(f) if str(f) != "" else "-" for f in fields))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    args = argv[2:]
    try:
        if cmd == "path":
            print(config_path())
            return 0
        if cmd == "init":
            p = config_path()
            if os.path.exists(p):
                print("exists: %s" % p)
                return 0
            try:
                os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
                with open(p, "x", encoding="utf-8") as f:  # "x": never truncate a file that appeared meanwhile
                    f.write(DEFAULT_TOML)
            except OSError as e:
                raise ConfigError("%s: cannot write: %s" % (p, e.strerror or e))
            print("wrote: %s" % p)
            print("")
            print("This one file is where multi is configured: which backends exist, which")
            print("models each one tries in order, endpoints, timeouts, and named profiles.")
            print("Every field is explained in a comment inside it. Keys are NOT in it:")
            print("  setup.sh set OPENROUTER_API_KEY     (prompts, never echoes)")
            print("Edit it, then check what multi will actually run with:")
            print("  setup.sh status")
            return 0
        cfg, source = load()
        if cmd == "check":
            print("config: %s" % source)
            print("backends: %s" % ", ".join(cfg["backends"]))
            print("profiles: %s (default: %s)" % (", ".join(cfg["profiles"]), cfg["default_profile"]))
            return 0
        if cmd == "backends":
            for name, b in cfg["backends"].items():
                _line(name, b["type"], " ".join(b["models"]), b["base_url"], b["api_key_env"], b["timeout"], b["stall"])
            return 0
        if cmd == "resolve":
            spec, timeout = None, None
            i = 0
            while i < len(args):
                if args[i] == "--backend" and i + 1 < len(args):
                    spec = args[i + 1]; i += 2
                elif args[i] == "--timeout" and i + 1 < len(args):
                    timeout = _positive_int("--timeout", "value", int(args[i + 1]) if args[i + 1].isdigit() else args[i + 1]); i += 2
                else:
                    raise ConfigError("resolve: unknown argument %r" % args[i])
            for p in resolve(cfg, spec):
                # A floor, not a replacement: the review skill passes 2400 to give
                # slow reviewers room, and a backend the user set higher keeps it.
                _line(p["suffix"], p["name"], p["type"], p["pinned"], " ".join(p["chain"]),
                      p["base_url"], p["api_key_env"], max(timeout or 0, p["timeout"]), p["stall"])
            return 0
        sys.stderr.write((__doc__ or "").split("\n\n")[1] + "\n")
        return 2
    except ConfigError as e:
        sys.stderr.write("multi config: %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
