#!/usr/bin/env python3
"""Extract Copilot's completed answer from --output-format=json JSONL.

The stream also contains prompts, tool output, progress deltas and usage. Only
the final assistant.message is an answer; a partial or failed run is not one.
"""
import json
import sys


def main(raw_path, out_path):
    answer = None
    model = None
    completed = False
    try:
        with open(raw_path, encoding="utf-8") as stream:
            for line in stream:
                if not line.strip():
                    continue
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError("event is not an object")
                data = event.get("data") or {}
                if not isinstance(data, dict):
                    raise ValueError("event data is not an object")
                if event.get("type") == "session.auto_mode_resolved":
                    model = data.get("chosenModel") or model
                elif (event.get("type") == "assistant.message"
                      and data.get("phase") in (None, "final_answer")
                      and not data.get("toolRequests")):
                    answer = data.get("content")
                    model = data.get("model") or model
                elif event.get("type") == "result":
                    completed = event.get("exitCode") == 0
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print("copilot JSONL could not be read: %s" % exc, file=sys.stderr)
        return 2
    if not completed or not isinstance(answer, str) or not answer.strip():
        print("copilot did not emit a completed, non-empty final answer", file=sys.stderr)
        return 3
    if not isinstance(model, str) or not model.strip() or any(c.isspace() for c in model):
        model = "unknown"
    try:
        with open(out_path, "w", encoding="utf-8") as out:
            out.write("Copilot (model: %s)\n\n%s\n" % (model, answer.strip()))
    except OSError as exc:
        print("copilot answer could not be written: %s" % exc, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
