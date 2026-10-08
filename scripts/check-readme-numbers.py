"""Every number in the README's benchmark table must appear in docs/benchmark.md.
Usage: check-readme-numbers.py README.md docs/benchmark.md"""
import re, sys

readme, bench = open(sys.argv[1]).read(), open(sys.argv[2]).read()
section = re.search(r"^## Benchmark\n(.*?)(?=^## |\Z)", readme, re.M | re.S)
if not section:
    print("no '## Benchmark' section in", sys.argv[1]); sys.exit(1)
table = "\n".join(l for l in section.group(1).splitlines() if l.startswith("|"))
numbers = set(re.findall(r"\$?\d+(?:\.\d+)?(?:/\d+)?", table))
missing = sorted(n for n in numbers if n not in bench)
for n in missing:
    print("README number not in benchmark:", n)
sys.exit(1 if missing else 0)
