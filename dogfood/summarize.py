"""Summarise dogfood runs: python3 -I dogfood/summarize.py dogfood/results > dogfood/results/summary.csv

One row per <task>.<tool>.<model>.<rep>.jsonl (stream-json from `claude -p`).
"""
import collections, csv, glob, json, os, sys

MARKERS = {"unverified": "UNVERIFIED", "failed": "FAILED", "crashed": "APP CRASHED", "usage": "usage:"}


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(text_of(c.get("text", "")) if isinstance(c, dict) else str(c) for c in content)
    return ""


def summarise(path):
    run = os.path.basename(path)[: -len(".jsonl")]
    task, tool, model, rep = run.split(".")
    calls = collections.Counter()
    marks = collections.Counter()
    result_chars = collections.Counter()
    names = {}
    final = {}
    for line in open(path, encoding="utf-8"):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "assistant":
            for b in ev["message"].get("content", []):
                if b.get("type") == "tool_use":
                    name = b["name"].split("__")[-1]
                    calls[name] += 1
                    names[b["id"]] = name
        elif ev.get("type") == "user":
            content = ev.get("message", {}).get("content", [])
            for b in content if isinstance(content, list) else []:
                if b.get("type") == "tool_result":
                    t = text_of(b.get("content"))
                    result_chars[names.get(b.get("tool_use_id"), "?")] += len(t)
                    for k, m in MARKERS.items():
                        marks[k] += t.count(m)
        elif ev.get("type") == "result":
            final = ev
    usage = final.get("usage", {})
    return {
        "run": run, "task": task, "tool": tool, "model": model, "rep": rep,
        "subtype": final.get("subtype", "missing"),
        "turns": final.get("num_turns", ""),
        "cost_usd": round(final.get("total_cost_usd", 0) or 0, 4),
        "duration_s": round((final.get("duration_ms", 0) or 0) / 1000, 1),
        "input_tokens": usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0)
                        + usage.get("cache_creation_input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "tool_calls": sum(calls.values()),
        "calls": " ".join(f"{k}={v}" for k, v in sorted(calls.items())),
        "result_chars": " ".join(f"{k}={v}" for k, v in sorted(result_chars.items())),
        **{k: marks[k] for k in MARKERS},
        "claim": (final.get("result") or "").replace("\n", " ")[:400],
    }


def main():
    rows = [summarise(p) for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl")))
            if not p.endswith(".trace.jsonl")]
    if not rows:
        return
    w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]))
    w.writeheader()
    w.writerows(rows)


if __name__ == "__main__":
    main()
