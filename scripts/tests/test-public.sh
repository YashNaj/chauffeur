#!/bin/bash
# Tests check-public.sh and select-public.py: bash scripts/tests/test-public.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# Leak check
mkdir -p "$T/clean" "$T/dirty"
echo 'path = "/Users/u/Library"' > "$T/clean/a.swift"
# Banned strings are assembled at run time so this file never contains them literally (the CI leak check reads it).
printf 'see /Users/%s/x\n' "Ya""sh" > "$T/dirty/a.md"
printf 'PNG\0\0com.%s.native\0' "MY""NEGLOBAL" > "$T/dirty/b.png"
"$ROOT/scripts/check-public.sh" "$T/clean" >/dev/null && ok "clean tree passes" || bad "clean tree passes"
out=$("$ROOT/scripts/check-public.sh" "$T/dirty"); rc=$?
[ $rc -eq 1 ] && ok "dirty tree fails" || bad "dirty tree fails (rc=$rc)"
grep -q "a.md:1" <<<"$out" && ok "reports file:line" || bad "reports file:line: $out"
grep -q "b.png" <<<"$out" && ok "finds a leak inside a binary file" || bad "binary leak: $out"

# Allowlist selection
mkdir -p "$T/repo/docs/superpowers/plans" "$T/repo/dogfood/results" "$T/repo/Sources"
touch "$T/repo/docs/design.md" "$T/repo/docs/superpowers/plans/p.md" "$T/repo/dogfood/run.sh" \
      "$T/repo/dogfood/results/F1.chauffeur.opus.1.jsonl" "$T/repo/Sources/a.swift" "$T/repo/notes.txt"
(cd "$T/repo" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm t)
printf '# test list\nSources/**\ndocs/**\ndogfood/**\n!docs/superpowers/**\n!dogfood/results/*.jsonl\n' > "$T/repo/list.txt"
sel=$(python3 -I "$ROOT/scripts/select-public.py" "$T/repo" "$T/repo/list.txt")
grep -qx "docs/design.md" <<<"$sel" && ok "selects docs" || bad "selects docs: $sel"
grep -q "superpowers" <<<"$sel" && bad "excludes docs/superpowers: $sel" || ok "excludes docs/superpowers"
grep -q "jsonl" <<<"$sel" && bad "excludes raw results: $sel" || ok "excludes raw results"
grep -qx "notes.txt" <<<"$sel" && bad "unlisted file stays private" || ok "unlisted file stays private"
exit $fail
