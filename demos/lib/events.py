"""Turns a stamped stream-json run into panel events: events.py <stamped.jsonl> <out.tsv>"""
import json, os, re, sys


def short(text, n=110):
    text = " ".join(text.split("\n", 1)[0].replace("**", "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def tool_text(content):
    if isinstance(content, str):
        return content
    return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))


DETAIL = ("APP CRASHED", "APP EXITED", "reason:", "hint:", "screen:", "+ ", "- ")


def main(argv):
    turns, tokens, cost, rows = 0, 0, 0.0, []
    home = os.path.expanduser("~")

    def add(t, kind, text, n=110):  # counters as they stand at this event; local paths redacted before shortening
        # A path under home names the viewer's projects: show none of it. Temp paths keep their (random) names.
        text = re.sub(r"~/[^\s,;'\"()\[\]]*", "~/…", text.replace(home, "~"))
        text = re.sub(r"(/private)?/var/folders/[^/\s]+/[^/\s]+/T", "$TMPDIR", text)
        rows.append((t, kind, short(text, n), turns, tokens, cost))

    for line in open(argv[0]):
        o = json.loads(line)
        t = o.get("t", 0)
        if o.get("type") == "assistant":
            usage = o.get("message", {}).get("usage", {})
            tokens += sum(usage.get(k, 0) for k in ("input_tokens", "output_tokens", "cache_read_input_tokens",
                                                     "cache_creation_input_tokens"))
            for c in o.get("message", {}).get("content", []):
                if c.get("type") == "tool_use":
                    turns += 1
                    name = c["name"].split("__")[-1]
                    args = " ".join(f"{v}" for v in c.get("input", {}).values())
                    add(t, "call", f"{name} {args}")
        elif o.get("type") == "user":
            for c in o.get("message", {}).get("content", []):
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    text = tool_text(c.get("content", ""))
                    add(t, "result", text)
                    for line in [l for l in text.splitlines()[1:] if l.startswith(DETAIL)][:3]:  # what explains the outcome
                        add(t, "detail", line)
        elif o.get("type") == "result":
            turns = o.get("num_turns", turns)
            cost = o.get("total_cost_usd", cost)
            add(t, "answer", o.get("result", ""), 300)
    with open(argv[1], "w") as f:
        for t, kind, text, n, tok, c in rows:
            f.write(f"{t}\t{kind}\t{text}\t{n}\t{tok}\t{c:.3f}\n")


if __name__ == "__main__":
    main(sys.argv[1:])
