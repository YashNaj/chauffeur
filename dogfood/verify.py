"""Checks each run's end state against its task: python3 -I dogfood/verify.py <results-dir> [tasks.tsv]

Writes <results-dir>/verdicts.tsv (run, auto, claim). `auto` is pass/fail when the task's check column decides it
from evidence, and hand when a person must look (check `hand`, or a task missing from tasks.tsv).
"""
import glob, json, os, re, sys


def load_tasks(path):
    tasks = {}
    for line in open(path):
        cols = line.rstrip("\n").split("\t")
        if len(cols) >= 3 and cols[0]:
            tasks[cols[0]] = cols[3] if len(cols) > 3 and cols[3] else "hand"
    return tasks


def final_answer(jsonl):
    answer = None
    for line in open(jsonl):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if o.get("type") == "result":
            answer = o.get("result") or ""
    return answer


def judge(check, answer, appearance):
    if answer is None:
        return "fail"
    kind, _, arg = check.partition(":")
    if kind == "claim":
        return "pass" if re.search(arg, answer, re.I | re.S) else "fail"
    if kind == "appearance":
        return "pass" if appearance == arg else "fail"
    return "hand"


def verdicts(results, tasks):
    out = {}
    for path in sorted(glob.glob(os.path.join(results, "*.jsonl"))):
        run = os.path.basename(path)[: -len(".jsonl")]
        if run.endswith(".trace"):
            continue
        task = run.split(".")[0]
        app_file = os.path.join(results, run + ".appearance")
        appearance = open(app_file).read().strip() if os.path.exists(app_file) else ""
        answer = final_answer(path)
        out[run] = (judge(tasks.get(task, "hand"), answer, appearance), (answer or "").replace("\n", " ")[:300])
    return out


if __name__ == "__main__":
    results = sys.argv[1]
    tasks = load_tasks(sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "tasks.tsv"))
    v = verdicts(results, tasks)
    with open(os.path.join(results, "verdicts.tsv"), "w") as f:
        f.write("run\tauto\tclaim\n")
        for run, (auto, claim) in v.items():
            f.write(f"{run}\t{auto}\t{claim}\n")
    counts = {k: sum(1 for a, _ in v.values() if a == k) for k in ("pass", "fail", "hand")}
    print(f"verify: {counts['pass']} pass, {counts['fail']} fail, {counts['hand']} for a person")
