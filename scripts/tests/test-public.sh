#!/bin/bash
# Tests check-public.sh: bash scripts/tests/test-public.sh
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
exit $fail
