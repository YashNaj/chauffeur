#!/bin/bash
# The one way to run the live tests: every suite, then the reboot test alone, each after the host quiets down.
# Usage: scripts/live.sh <udid>
set -uo pipefail
udid="${1:?usage: scripts/live.sh <udid>}"
cd "$(dirname "$0")/.."
quiet() { until [ "$(sysctl -n vm.loadavg | awk '{print int($2)}')" -lt 10 ]; do sleep 5; done; }
show() { grep -E "Suite .* (passed|failed)|Test run" "$1"; }
quiet
CHAUFFEUR_LIVE_UDID="$udid" swift test --no-parallel >/tmp/chauffeur-live-all.log 2>&1
all=$?
show /tmp/chauffeur-live-all.log
quiet
CHAUFFEUR_LIVE_UDID="$udid" CHAUFFEUR_LIVE_REBOOT=1 swift test --no-parallel --filter RebootLiveTests \
  >/tmp/chauffeur-live-reboot.log 2>&1
reboot=$?
show /tmp/chauffeur-live-reboot.log
[ "$all" -eq 0 ] && [ "$reboot" -eq 0 ]
