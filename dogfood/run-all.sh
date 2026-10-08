#!/bin/bash
# Runs every task on both arms, one at a time: dogfood/run-all.sh <model> <rep> [task ids...]
# Waits for load < 20 before each run and stops when the summed cost reaches $CAP (default 50).
set -uo pipefail
MODEL=$1 REP=$2; shift 2
DIR="$(cd "$(dirname "$0")" && pwd)"
CAP=${CAP:-50}
export RESULTS="${RESULTS:-$DIR/results}"
TASKS=("$@"); [ ${#TASKS[@]} -gt 0 ] || TASKS=(F1 F2 F3 F4 F5 F6 F7 F8 F9 S1 S2 S3 C1 K1 R1)
spent() { python3 -I "$DIR/summarize.py" "$RESULTS" | python3 -I -c 'import csv,sys; print(round(sum(float(r["cost_usd"]) for r in csv.DictReader(sys.stdin)),2))'; }
for t in "${TASKS[@]}"; do
  for tool in chauffeur xcode; do
    [ -f "$RESULTS/$t.$tool.$MODEL.$REP.jsonl" ] && { echo "skip $t.$tool (done)"; continue; }
    s=$(spent); awk -v s="$s" -v c="$CAP" 'BEGIN{exit !(s>=c)}' && { echo "CAP reached: \$$s"; exit 4; }
    while awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l>20)}'; do sleep 15; done
    "$DIR/run.sh" "$t" "$tool" "$MODEL" "$REP" || echo "run.sh failed for $t.$tool"
    echo "spent so far: \$$(spent)"
  done
done
echo "ALL DONE"
