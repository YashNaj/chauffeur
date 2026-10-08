#!/bin/bash
# Everything CI's build-test job runs (M4a spec §6). Passing here means passing CI, except for the Xcode version:
# CI builds with Xcode 26, so a release still needs a green CI run on its exact commit.
# Usage: scripts/check.sh
set -uo pipefail
cd "$(dirname "$0")/.."
step() {
  local name=$1; shift
  echo "== $name"
  "$@" || { echo "check: failed at $name" >&2; exit 1; }
}
step format xcrun swift-format lint --strict -r Sources Tests
step code scripts/check-code.sh
step build swift build -Xswiftc -warnings-as-errors
step release swift build -c release -Xswiftc -warnings-as-errors
step test swift test -Xswiftc -warnings-as-errors
step verifier python3 -I -B dogfood/test_verify.py
step readme python3 -I -B scripts/check-readme-numbers.py README.md docs/benchmark.md
step readme-tests python3 -I -B scripts/tests/test_readme_numbers.py
step demos python3 -I -B demos/lib/test_events.py
for t in scripts/tests/*.sh; do step "$(basename "$t")" bash "$t"; done
echo "check: all passed"
