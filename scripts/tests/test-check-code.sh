#!/bin/bash
# Tests check-code.sh: bash scripts/tests/test-check-code.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# A minimal clean tree; prints its path.
tree() {
  local d="$T/$1"
  mkdir -p "$d/Sources/ChauffeurCore" "$d/Sources/ChauffeurBridge" "$d/Sources/chauffeur" "$d/Tests/X"
  echo 'let a = 1' > "$d/Sources/ChauffeurCore/A.swift"
  echo "$d"
}
lines() { local i; for ((i = 0; i < $1; i++)); do echo "let v$i = $i"; done; }
expect_fail() {
  local name=$1 rule=$2 dir=$3 out rc
  out=$("$ROOT/scripts/check-code.sh" "$dir"); rc=$?
  if [ $rc -eq 1 ] && grep -q ": $rule:" <<<"$out"; then ok "$name"; else bad "$name (rc=$rc): $out"; fi
}
expect_pass() {
  local name=$1 dir=$2 out rc
  out=$("$ROOT/scripts/check-code.sh" "$dir"); rc=$?
  if [ $rc -eq 0 ]; then ok "$name"; else bad "$name (rc=$rc): $out"; fi
}

expect_pass "clean tree passes" "$(tree clean)"

d=$(tree bridge); echo 'let h = dlopen(nil, 0)' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "dlopen outside the bridge fails" bridge "$d"
d=$(tree bridge-ok); echo 'void *h = dlopen(0, 0);' > "$d/Sources/ChauffeurBridge/B.m"
expect_pass "dlopen inside the bridge passes" "$d"

d=$(tree trybang); echo 'let x = try! f()' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "try! fails" try-bang "$d"

d=$(tree print); printf 'func f() {\n    print("x")\n}\n' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "print in ChauffeurCore fails" print "$d"
d=$(tree print-cli); echo 'print("x")' > "$d/Sources/chauffeur/main.swift"
expect_pass "print in the CLI target passes" "$d"
d=$(tree comment); printf '    // print() would buffer; try! here would crash\n' > "$d/Sources/ChauffeurCore/B.swift"
expect_pass "comment line passes" "$d"

d=$(tree long); lines 401 > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "401-line source file fails" file-length "$d"
d=$(tree long-test); lines 401 > "$d/Tests/X/BTests.swift"
expect_pass "401-line test file passes" "$d"
d=$(tree longer-test); lines 601 > "$d/Tests/X/BTests.swift"
expect_fail "601-line test file fails" file-length "$d"

d=$(tree allow); echo 'let x = try! f() // check-code: allow try-bang — compile-time constant' > "$d/Sources/ChauffeurCore/B.swift"
expect_pass "allowed line with a reason passes" "$d"
d=$(tree allow-noreason); echo 'let x = try! f() // check-code: allow try-bang' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "allow without a reason fails" try-bang "$d"
d=$(tree allow-wrong); echo 'let x = try! f() // check-code: allow print — wrong rule' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "allow for another rule fails" try-bang "$d"

d=$(tree leak); printf 'see /Users/%s/x\n' "Ya""sh" > "$d/Sources/ChauffeurCore/notes.md"
expect_fail "private material fails" leak "$d"

d=$(tree "with space"); echo 'let x = try! f()' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "path with a space" try-bang "$d"

expect_pass "real tree passes" "$ROOT"
exit $fail
