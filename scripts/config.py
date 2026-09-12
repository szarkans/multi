#!/usr/bin/env python3
"""Read, validate and resolve the multi config — the one place backends live.

    config.py resolve [--backend SPEC] [--timeout N] [--ignore-avoid]
                      who runs, one line each (--timeout N is a FLOOR: each
                      backend gets max(N, its own); --ignore-avoid runs every
                      backend as if it had no avoid windows, for this run)
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
    suffix  name  type  pinned  chain  base_url  api_key_env  timeout  stall  closed
Empty fields print as "-" (a whitespace IFS in bash would swallow them).
`closed` is "-" when the backend may run now, or one sentence saying which
`avoid` window it is sitting out and when it is back; ask.sh writes that
sentence as the backend's answer instead of launching it. MULTI_NOW=<epoch>
in the environment evaluates the windows at that instant instead of the
clock — for tests.
`pinned` is the model named as backend:model — exactly that model, no
fallback. `chain` is the backend's own model list, space-separated, walked in
order when nothing is pinned. `suffix` is the answer-file suffix: name, or
name-2, name-3 for a repeated backend.
"""
import os
import re
import sys
import time
from urllib.parse import urlsplit

try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_vendor"))
    import tomli as tomllib  # type: ignore

TYPES = ("claude-headless", "codex", "opencode", "gemini")
BACKEND_KEYS = {"type", "models", "base_url", "api_key_env", "timeout", "stall", "avoid"}
TOP_KEYS = {"backends", "profiles", "default_profile"}
DEFAULT_TIMEOUT = 300
DEFAULT_STALL = 180
# claude-headless is killed for silence, not for the clock: its transcript
# grows with every turn, and a model still growing it is still working.
# Measured 2026-09-12: a flash model was cut at 300s after 38 live turns, paid
# for and discarded. The stall is 600, not the old 300: one turn measured 266s
# with the transcript still (providers.sh, "Why 2400"), and silence is not
# billed, so a generous stall costs only a slower verdict on a dead key. The
# timeout is only a ceiling against a model that keeps busy for ever, and
# every turn of that is billed.
HEADLESS_STALL = 600
HEADLESS_TIMEOUT = 1800

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
# timeout: seconds per run, default 300 (claude-headless: 1800, a ceiling).
#   ask.sh --timeout N raises every backend to at least N for that run (the
#   review skill passes 2400) and never lowers one. stall (opencode,
#   claude-headless): seconds of silence before the model is declared dead,
#   default 180 (claude-headless: 600 without its transcript growing).
#
# profiles: named lists of who runs, in parallel. An entry is a backend name
# (its whole chain) or backend:model (exactly that model, no fallback). The
# same entry twice runs twice. ask.sh --backend <profile> picks one;
# --backend a,b:model is a one-off profile; no --backend = default_profile.
# avoid: windows a backend sits out, UTC only: ["Mon-Fri 06:00-10:00 UTC"];
#   ask.sh --ignore-avoid lifts them for one run.

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


# --- avoid: windows a backend sits out ----------------------------------
# A provider that bills by the hour (DeepSeek: peak Mon-Fri 01:00-04:00 and
# 06:00-10:00 UTC, double price, moved 2026-08-16) publishes its windows in
# UTC, so the config takes them in UTC and nothing else: no local zone, no
# DST arithmetic, no "was that Beijing or London". One string per window:
#   "Mon-Fri 06:00-10:00 UTC"   weekdays, those hours
#   "Sat-Sun 00:00-24:00 UTC"   the whole weekend
#   "22:00-02:00 UTC"           every day; wraps past midnight
# The day names the window's START; the end is exclusive. Evaluated once, at
# launch: a review that starts at 09:50 in an open hour runs to its end.
DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
WEEK = 7 * 1440
_WINDOW = re.compile(r"^(?:(Mon|Tue|Wed|Thu|Fri|Sat|Sun)(?:-(Mon|Tue|Wed|Thu|Fri|Sat|Sun))?\s+)?"
                     r"(\d{2}):(\d{2})-(\d{2}):(\d{2})\s+UTC$")


def _parse_window(where, text):
    """'Mon-Fri 06:00-10:00 UTC' -> (text, [(start_minute_of_week, length)...])."""
    m = _WINDOW.match(text.strip()) if isinstance(text, str) else None
    if not m:
        raise ConfigError("%s: avoid entries look like \"Mon-Fri 06:00-10:00 UTC\" or \"22:00-02:00 UTC\" — days optional, hours in UTC (the zone is required and only UTC is accepted), got %r" % (where, text))
    d1, d2, h1, m1, h2, m2 = m.groups()
    h1, m1, h2, m2 = int(h1), int(m1), int(h2), int(m2)
    if h1 > 23 or m1 > 59 or m2 > 59 or h2 > 24 or (h2 == 24 and m2 != 0):
        raise ConfigError("%s: avoid: %r is not a time of day" % (where, text))
    start, end = h1 * 60 + m1, h2 * 60 + m2
    length = (end - start) % 1440 or (1440 if end == 1440 else 0)  # 22:00-02:00 wraps; 00:00-24:00 is a day; 10:00-10:00 is nothing
    if length == 0:
        raise ConfigError("%s: avoid: %r is an empty window" % (where, text))
    if d1 is None:
        days = list(range(7))
    else:
        a, b = DAYS.index(d1), DAYS.index(d2 or d1)
        days = [(a + i) % 7 for i in range((b - a) % 7 + 1)]
    return (" ".join(text.split()), [(d * 1440 + start, length) for d in days])


def _closed_now(windows, now):
    """Return '' if open at `now` (epoch), else why not and when it is back."""
    t = time.gmtime(now)
    minute = t.tm_wday * 1440 + t.tm_hour * 60 + t.tm_min
    spans = [(text, s, l) for text, ss in windows for s, l in ss]
    inside = lambda m, s, l: (m - s) % WEEK < l  # noqa: E731
    hit = [(text, s, l) for text, s, l in spans if inside(minute, s, l)]
    if not hit:
        return ""
    text, s, l = hit[0]
    # "back at" is when the backend can actually run, not where this one span
    # ends: "Sat-Sun 00:00-24:00" is two day-spans and Saturday's end is not a
    # reopening. Walk through every span that covers the end, furthest first,
    # until none does -- or a whole week is covered and it never reopens.
    back, closed_for = s + l, l - (minute - s) % WEEK
    while closed_for < WEEK:
        more = [l2 - (back - s2) % WEEK for _, s2, l2 in spans if inside(back, s2, l2)]
        if not more:
            break
        back += max(more); closed_for += max(more)
    if closed_for >= WEEK:
        return "sits out every hour of the week (avoid, in config.toml) — it will never run; drop a window"
    return "sits out %s (avoid, in config.toml) — now %s, back at %s" % (text, _clock(minute), _clock(back))


def _clock(minute_of_week):
    m = minute_of_week % WEEK
    return "%s %02d:%02d UTC" % (DAYS[m // 1440], (m % 1440) // 60, m % 60)


class ConfigError(Exception):
    pass


def config_path():
    if os.environ.get("MULTI_CONFIG"):
        return os.environ["MULTI_CONFIG"]
    home = os.environ.get("MULTI_HOME") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "multi"
    )
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
        if "stall" in b and t not in ("opencode", "claude-headless"):
            raise ConfigError("%s: stall only applies to type = \"opencode\" or \"claude-headless\"" % w)
        key_env = b.get("api_key_env", name.upper().replace("-", "_") + "_API_KEY")
        # It is expanded by name in bash (eval "key=\${$key_env:-}"), so it must
        # be a plain identifier — anything else is a shell injection waiting
        # for a pasted config.
        if not isinstance(key_env, str) or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key_env):
            raise ConfigError("%s: api_key_env must be a variable name (letters, digits, _), got %r" % (w, key_env))
        avoid = b.get("avoid", [])
        if not isinstance(avoid, list):
            raise ConfigError("%s: avoid must be a list of windows, e.g. [\"Mon-Fri 06:00-10:00 UTC\"]" % w)
        backends[name] = {
            "avoid": [_parse_window(w, a) for a in avoid],
            "type": t,
            "models": models,
            "base_url": base_url,
            "api_key_env": key_env.strip(),
            "timeout": _positive_int(w, "timeout", b.get("timeout", HEADLESS_TIMEOUT if t == "claude-headless" else DEFAULT_TIMEOUT)),
            "stall": _positive_int(w, "stall", b.get("stall", HEADLESS_STALL if t == "claude-headless" else DEFAULT_STALL)),
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


def resolve(cfg, spec=None, now=None, ignore_avoid=False):
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
        # A backend inside one of its avoid windows is still a participant: the
        # entry stays, the column says why it will not run. The user put the
        # window there; the report names the hour, not a missing reviewer.
        closed = "" if ignore_avoid else _closed_now(backends[name]["avoid"], now)
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
            "timeout": b["timeout"], "stall": b["stall"], "closed": closed,
        })
    return out


def _line(*fields):
    for f in fields:
        if "\t" in str(f) or "\n" in str(f):
            raise ConfigError("a config value contains a tab or newline: %r" % f)
    print("\t".join(str(f) if str(f) != "" else "-" for f in fields))


def main(argv):
    # MULTI_NOW=<epoch>: evaluate avoid windows at that instant -- tests only.
    now = os.environ.get("MULTI_NOW") or time.time()
    cmd = argv[1] if len(argv) > 1 else ""
    args = argv[2:]
    try:
        try:
            now = int(now); time.gmtime(now)
        except (ValueError, OverflowError, OSError):
            raise ConfigError("MULTI_NOW must be an epoch second, got %r" % now)
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
                _line(name, b["type"], " ".join(b["models"]), b["base_url"], b["api_key_env"], b["timeout"], b["stall"],
                      ", ".join(t for t, _ in b["avoid"]), _closed_now(b["avoid"], now))
            return 0
        if cmd == "resolve":
            spec, timeout, ignore_avoid = None, None, False
            i = 0
            while i < len(args):
                if args[i] == "--ignore-avoid":  # the user said "run it anyway": one run, no config edit
                    ignore_avoid = True; i += 1
                elif args[i] == "--backend" and i + 1 < len(args):
                    spec = args[i + 1]; i += 2
                elif args[i] == "--timeout" and i + 1 < len(args):
                    timeout = _positive_int("--timeout", "value", int(args[i + 1]) if args[i + 1].isdigit() else args[i + 1]); i += 2
                else:
                    raise ConfigError("resolve: unknown argument %r" % args[i])
            for p in resolve(cfg, spec, now, ignore_avoid):
                # A floor, not a replacement: the review skill passes 2400 to give
                # slow reviewers room, and a backend the user set higher keeps it.
                _line(p["suffix"], p["name"], p["type"], p["pinned"], " ".join(p["chain"]),
                      p["base_url"], p["api_key_env"], max(timeout or 0, p["timeout"]), p["stall"],
                      p["closed"])
            return 0
        sys.stderr.write((__doc__ or "").split("\n\n")[1] + "\n")
        return 2
    except ConfigError as e:
        sys.stderr.write("multi config: %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
