#!/usr/bin/env python3
"""Training verdicts and the Kilo catalogue's closed, cacheable projection."""
import fnmatch
import json
import re
import sys
from urllib.parse import urlsplit


# First match wins. Account overrides and Kilo's per-model catalogue precede
# this table; everything unrecognised remains unknown. Hosts are exact.
RULES = (
    # OpenAI API data is not trained on by default, but codex usually runs on a
    # ChatGPT plan, where it is an account setting we cannot see -> unknown.
    # https://openai.com/policies/how-your-data-is-used-to-improve-model-performance/ (checked 2026-10-04)
    ("codex", "*", "*", "unknown"),
    # https://www.anthropic.com/legal/commercial-terms (checked 2026-10-04)
    ("claude-headless", "api.anthropic.com", "*", "no"),
    # OpenRouter :free models train; paid depends on the account's data_collection setting.
    # https://openrouter.ai/docs/guides/routing/provider-selection (checked 2026-10-04)
    ("claude-headless", "openrouter.ai", "*:free", "yes"),
    ("claude-headless", "openrouter.ai", "*", "unknown"),
    # https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html (checked 2026-10-04)
    ("claude-headless", "api.deepseek.com", "*", "yes"),
    # https://docs.z.ai/legal-agreement/privacy-policy (checked 2026-10-04)
    ("claude-headless", "api.z.ai", "*", "yes"),
    ("claude-headless", "open.bigmodel.cn", "*", "yes"),
    # OpenCode free channel: assumed to train (checked 2026-10-04).
    ("opencode", "*", "opencode/*", "yes"),
    # Kilo :free models; the gateway catalogue (per model) wins over this row.
    # https://kilo.ai/docs/gateway (checked 2026-10-04)
    ("kilo", "*", "kilo/*:free", "yes"),
    # https://ai.google.dev/gemini-api/terms (checked 2026-10-04)
    ("gemini", "*", "*", "yes"),
    ("*", "*", "*", "unknown"),
)


def verdict(backend_type, model, base_url="", override="unknown", rows=""):
    if override in ("true", "false"):
        return "yes" if override == "true" else "no"
    # Only kilo/<id> names are in the gateway catalogue; any other id goes to the rules.
    if backend_type == "kilo" and model.startswith("kilo/"):
        for line in rows.splitlines():
            fields = line.split("\t")
            if len(fields) == 2 and fields[0] == model[5:] and fields[1] in ("yes", "no"):
                return fields[1]
    host = urlsplit(base_url).hostname or ""
    for kind, hostname, pattern, result in RULES:
        if kind in ("*", backend_type) and hostname in ("*", host) and fnmatch.fnmatchcase(model, pattern):
            return result
    return "unknown"


def catalogue(raw):
    """Validate completely before emitting anything; absent flags stay unknown."""
    data = json.loads(raw)
    models = data.get("data") if isinstance(data, dict) else None
    if not isinstance(models, list) or not models:
        raise ValueError("expected a non-empty data list")
    seen, rows = set(), []
    for model in models:
        if not isinstance(model, dict):
            raise ValueError("expected model objects")
        model_id = model.get("id")
        # An id we could not write safely as one TSV field is skipped, not
        # fatal: the live catalogue carries `~vendor/x-latest` aliases, and one
        # odd id used to throw away every flag (measured 2026-10-04).
        if not isinstance(model_id, str) or not re.fullmatch(r"[A-Za-z0-9._:/@+~-]+", model_id):
            continue
        if model_id in seen:
            raise ValueError("duplicate model id")
        seen.add(model_id)
        if "mayTrainOnYourPrompts" not in model:
            continue
        trains = model["mayTrainOnYourPrompts"]
        if not isinstance(trains, bool):
            raise ValueError("mayTrainOnYourPrompts must be boolean")
        rows.append(model_id + "\t" + ("yes" if trains else "no"))
    if not rows:
        raise ValueError("no training flags")
    return "\n".join(rows)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["catalogue"]:
            print(catalogue(sys.stdin.read()))
        else:
            # TYPE BASE_URL OVERRIDE ROWS_FILE MODEL... -> one verdict per line.
            # The rows come from a file: a 128 KB argv string is the ceiling.
            btype, base_url, override, rows_file, models = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
            rows = open(rows_file).read() if rows_file else ""
            for m in models:
                print(verdict(btype, m, base_url, override, rows))
    except (ValueError, TypeError, OSError, IndexError) as exc:
        sys.stderr.write("multi training: %s\n" % exc)
        sys.exit(2)
