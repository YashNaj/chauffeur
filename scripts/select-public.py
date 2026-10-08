"""Prints the files the public allowlist selects: select-public.py <repo-root> [list-file]

Candidates are tracked files plus untracked, unignored ones. A line is an fnmatch glob (`**` crosses directories);
a line starting with `!` excludes; `#` starts a comment. The last matching line wins.
"""
import fnmatch, subprocess, sys

root = sys.argv[1]
listfile = sys.argv[2] if len(sys.argv) > 2 else root + "/scripts/public-files.txt"
rules = []
for raw in open(listfile):
    line = raw.split("#", 1)[0].strip()
    if line:
        rules.append((not line.startswith("!"), line.lstrip("!")))
files = subprocess.run(["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard"],
                       capture_output=True, text=True, check=True).stdout.split("\n")
for f in sorted(set(filter(None, files))):
    keep = False
    for include, pattern in rules:
        if fnmatch.fnmatch(f, pattern):
            keep = include
    if keep:
        print(f)
