#!/bin/bash
# The one way to run the live tests: every suite, then the reboot test alone, each after the host quiets down.
# Usage: scripts/live.sh <udid>
set -uo pipefail
udid="${1:?usage: scripts/live.sh <udid>}"
cd "$(dirname "$0")/.."
logs=$(mktemp -d "${TMPDIR:-/tmp}/chauffeur-live.XXXXXX")
quiet() { # wait up to 15 minutes for the 1-minute load to drop under 10, then give up with exit 2
  local n=0 load
  until load=$(sysctl -n vm.loadavg | awk '{print $2}'); [ "${load%%.*}" -lt 10 ]; do
    [ $((n++)) -ge 180 ] && { echo "live: the host stayed busy (1-minute load $load) for 15 minutes" >&2; exit 2; }
    sleep 5
  done
}
show() { grep -E "Suite .* (passed|failed)|Test run" "$1"; }
quiet
CHAUFFEUR_LIVE_UDID="$udid" swift test --no-parallel >"$logs/all.log" 2>&1
all=$?
show "$logs/all.log"
quiet
CHAUFFEUR_LIVE_UDID="$udid" CHAUFFEUR_LIVE_REBOOT=1 swift test --no-parallel --filter RebootLiveTests \
  >"$logs/reboot.log" 2>&1
reboot=$?
show "$logs/reboot.log"
# a renamed suite would make the filter match nothing and pass silently: insist that exactly one test ran
if [ "$reboot" -eq 0 ] && ! grep -q 'Test run with 1 test ' "$logs/reboot.log"; then
  echo "live: the reboot run did not run exactly one test (is RebootLiveTests renamed?): $logs/reboot.log" >&2; exit 1
fi
if [ "$all" -eq 0 ] && [ "$reboot" -eq 0 ]; then rm -rf "$logs"; else echo "live tests failed: logs in $logs (all.log, reboot.log)"; exit 1; fi
