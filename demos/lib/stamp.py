"""Adds a "t" field (seconds since start) to each stream-json line: claude -p ... | python3 -I stamp.py > run.jsonl"""
import json, sys, time

start = time.monotonic()
for line in sys.stdin:
    try:
        o = json.loads(line)
    except ValueError:
        continue
    o["t"] = round(time.monotonic() - start, 2)
    print(json.dumps(o), flush=True)
