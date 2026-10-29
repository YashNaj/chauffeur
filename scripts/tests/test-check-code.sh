#!/bin/bash
# Tests check-code.sh: bash scripts/tests/test-check-code.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
n=0
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

d=$(tree hid-owner); mkdir -p "$d/Sources/ChauffeurCore/Engine"
echo 'var hid: CHHIDClient?' > "$d/Sources/ChauffeurCore/Engine/Session.swift"
expect_fail "CHHIDClient outside HID.swift fails" hid-owner "$d"
d=$(tree doctor-bridge); printf 'import ChauffeurBridge\nimport Foundation\n' > "$d/Sources/ChauffeurCore/Doctor.swift"
expect_fail "Doctor importing ChauffeurBridge fails" doctor-bridge "$d"
d=$(tree device-bridge); mkdir -p "$d/Sources/ChauffeurCore/Device"
echo 'import ChauffeurBridge' > "$d/Sources/ChauffeurCore/Device/HID.swift"
expect_pass "a Device wrapper importing ChauffeurBridge passes" "$d"

d=$(tree trybang); echo 'let x = try! f()' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "try! fails" try-bang "$d"

d=$(tree print); printf 'func f() {\n    print("x")\n}\n' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "print in ChauffeurCore fails" print "$d"
d=$(tree print-cli); echo 'print("x")' > "$d/Sources/chauffeur/main.swift"
expect_pass "print in the CLI target passes" "$d"
d=$(tree comment); printf '    // print() would buffer; try! here would crash\n' > "$d/Sources/ChauffeurCore/B.swift"
expect_pass "comment line passes" "$d"

d=$(tree exit); echo 'return Output("x", exit: 1)' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "bare exit-code literal fails" exit-literal "$d"
d=$(tree exit-cli); echo 'let o = Output("x", exit: 64)' > "$d/Sources/chauffeur/main.swift"
expect_fail "bare exit-code literal in the CLI target fails" exit-literal "$d"
d=$(tree exit-case); printf 'return Output("x", exit: .error)\nreturn Output("x", exit: report.exitCode)\ncase ok = 0\n' > "$d/Sources/ChauffeurCore/B.swift"
expect_pass "ExitCode cases and raw values pass" "$d"

for shape in 'exit: anyDelivered ? 0 : 3)' 'exit: changed ? .ok : 3,' 'out.exit = 5' 'guard out.exit == 6 else { return out }' \
  'exit = alive ? 3 : 1' 'if result.exit != 0 {'; do
  n=$((n + 1)); d=$(tree "exit-shape-$n"); printf '%s\n' "$shape" > "$d/Sources/ChauffeurCore/B.swift"
  expect_fail "bare exit code fails: $shape" exit-literal "$d"
done
for shape in 'public init(_ text: String, exit: Int32 = 0, data: JSON? = nil) {' 'var exit: Int32 = 1' 'let exit: Int32 = 2'; do
  n=$((n + 1)); d=$(tree "exit-decl-$n"); printf '%s\n' "$shape" > "$d/Sources/ChauffeurCore/B.swift"
  expect_fail "bare exit-code default or initial value fails: $shape" exit-literal "$d"
done
d=$(tree exit-decl-ok); printf '%s\n' 'public init(_ text: String, exit: Int32 = ExitCode.ok.rawValue, data: JSON? = nil) {' \
  'var exit: Int32 = ExitCode.error.rawValue' > "$d/Sources/ChauffeurCore/B.swift"
expect_pass "exit: Int32 = ExitCode.ok.rawValue passes" "$d"
d=$(tree exit-report); echo 'return Output(report.render(), exit: report.exitCode, data: report.json)' > "$d/Sources/ChauffeurCore/B.swift"
expect_pass "exit: report.exitCode passes" "$d"
d=$(tree exit-ok); printf '%s\n' 'exit: alive ? .noEffect : .error)' 'out.exit = ExitCode.crashed.rawValue' \
  'guard out.exit == ExitCode.pending.rawValue else { return out }' 'self.exit = exit' 'exit(64)' \
  'return Output("simctl pbcopy exit: 3 (stderr: x)")' > "$d/Sources/ChauffeurCore/B.swift"
expect_pass "ExitCode ternaries, rawValue comparisons, process exits and prose pass" "$d"

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
d=$(tree leak-bin); printf 'x\0\377\376 /Users/%s/x\0' "Ya""sh" > "$d/Sources/ChauffeurCore/cache.pyc"
expect_fail "private material in a binary file fails" leak "$d"
d=$(tree leak-ignored); (cd "$d" && git init -q && echo 'cache/' > .gitignore)
mkdir -p "$d/cache"; printf 'see /Users/%s/x\n' "Ya""sh" > "$d/cache/run.log"
expect_pass "private material in a gitignored file passes" "$d"
printf 'see /Users/%s/x\n' "Ya""sh" > "$d/notes.md"
expect_fail "private material in an untracked file fails" leak "$d"

d=$(tree "with space"); echo 'let x = try! f()' > "$d/Sources/ChauffeurCore/B.swift"
expect_fail "path with a space" try-bang "$d"

expect_pass "real tree passes" "$ROOT"
exit $fail
