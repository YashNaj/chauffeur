#!/bin/bash
# M1 acceptance: fixture form + list flow and a Settings flow through the real CLI.
# Prints every command and result; screenshots each step to .build/acceptance/<udid>/ for outcome review.
set -uo pipefail
cd "$(dirname "$0")/.."
U=${1:?usage: Tests/acceptance.sh <udid>}
export CHAUFFEUR_UDID=$U
C=.build/debug/chauffeur
SHOTS=.build/acceptance/$U
mkdir -p "$SHOTS"
swift build >/dev/null || exit 1
pkill -f "chauffeur daemon" 2>/dev/null; sleep 1  # never test against a daemon from an older build (I6)
APP=$(Tests/FixtureApp/build.sh) && xcrun simctl install "$U" "$APP"
xcrun simctl terminate "$U" dev.chauffeur.fixture 2>/dev/null
xcrun simctl launch "$U" dev.chauffeur.fixture >/dev/null
pass=0; fail=0; n=0
step() {
  local want=$1; shift
  n=$((n + 1))
  out=$("$C" "$@" 2>&1); rc=$?
  xcrun simctl io "$U" screenshot "$SHOTS/$(printf %02d $n).png" >/dev/null 2>&1
  printf '%02d $ chauffeur %s\n%s\n[exit %d]\n\n' "$n" "$*" "$out" "$rc"
  if [ "$rc" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "!! expected exit $want"; fi
}
ref() { "$C" find "$1" | grep -o '\[e[0-9]*\]' | head -1 | tr -d '[]'; }

step 0 wait "Show alert" --timeout 30
step 0 snapshot
step 0 tap "$(ref 'Show alert')"
step 0 tap "$(ref 'button:OK')"
step 0 tap "$(ref 'tab:Form')"
step 3 tap "$(ref 'button:Submit')"
step 0 type "$(ref 'textfield:email')" "Ab@1.test_X"
step 0 type "$(ref 'securefield:')" "hunter2"
step 0 tap "$(ref 'switch:Agree')"
step 0 tap "$(ref 'button:Submit')"
step 0 find "Submitted"
step 0 tap "$(ref 'tab:Home')"
step 0 tap "$(ref 'button:Long list')"
step 0 scroll down --until "Row 40"

xcrun simctl launch "$U" com.apple.Preferences >/dev/null
step 0 wait "General" --timeout 30
step 0 tap "$(ref 'General')"
step 0 wait "About" --timeout 10
step 0 tap "$(ref 'About')"
step 0 snapshot
xcrun simctl terminate "$U" com.apple.Preferences

echo "passed $pass, failed $fail — screenshots in $SHOTS"
[ "$fail" = 0 ]
