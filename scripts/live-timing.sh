#!/bin/bash
# Times this branch against a base ref (default main) on a booted simulator: two rounds each, base first.
# Exits 1 when the branch is slower on any metric by more than max(50 ms, 5 %) in both rounds, 2 when the instrument itself failed.
# Usage: scripts/live-timing.sh <udid> [base-ref]
set -uo pipefail
udid="${1:?usage: scripts/live-timing.sh <udid> [base-ref]}"
base="${2:-main}"
cd "$(dirname "$0")/.."
tree="${TMPDIR:-/tmp}/chauffeur-timing-$(git rev-parse --short "$base")"
logs=$(mktemp -d "${TMPDIR:-/tmp}/chauffeur-timing-logs.XXXXXX")
trap 'git worktree remove --force "$tree" >/dev/null 2>&1; rm -rf "$logs"' EXIT
quiet() { until [ "$(sysctl -n vm.loadavg | awk '{print int($2)}')" -lt 10 ]; do sleep 5; done; }
die() { echo "live-timing: $1" >&2; [ -n "${2:-}" ] && tail -n 30 "$2" >&2; exit 2; }   # exit 2: the instrument failed, not the branch
git worktree remove --force "$tree" >/dev/null 2>&1
git worktree add --detach "$tree" "$base" >/dev/null || die "cannot add a worktree for $base"
cp Tests/ChauffeurCoreTests/Live/TimingLiveTests.swift "$tree/Tests/ChauffeurCoreTests/Live/"
for dir in "$tree" .; do
  quiet
  (cd "$dir" && swift build --build-tests >"$logs/build.log" 2>&1) || die "build failed in $dir" "$logs/build.log"
done
run() { # run <dir> -> its timing line plus the 1-minute load; a failing test, even one that printed a line, fails the run
  quiet
  (cd "$1" && CHAUFFEUR_LIVE_UDID="$udid" CHAUFFEUR_LIVE_TIMING=1 swift test --skip-build --filter TimingLiveTests) >"$logs/test.log" 2>&1 \
    || { echo "live-timing: the timing test failed in $1" >&2; tail -n 30 "$logs/test.log" >&2; return 2; }
  line=$(grep '^timing:' "$logs/test.log")
  [ -n "$line" ] || { echo "live-timing: no timing line from $1" >&2; tail -n 30 "$logs/test.log" >&2; return 2; }
  echo "$line load $(sysctl -n vm.loadavg | awk '{print $2}')"
}
b1=$(run "$tree") && h1=$(run .) && b2=$(run "$tree") && h2=$(run .) || exit 2
printf 'base   %s\nbranch %s\nbase   %s\nbranch %s\n' "$b1" "$h1" "$b2" "$h2"
fail=0
for m in tap dead type; do
  val() { echo "$1" | awk -v k="$m" '{for (i=1;i<NF;i++) if ($i==k) print $(i+1)}'; }
  read -r bm hm < <(awk -v a="$(val "$b1")" -v b="$(val "$b2")" -v c="$(val "$h1")" -v d="$(val "$h2")" \
    'BEGIN {print (a+b)/2, (c+d)/2}')
  slow=$(awk -v b1="$(val "$b1")" -v h1="$(val "$h1")" -v b2="$(val "$b2")" -v h2="$(val "$h2")" 'function t(x) {return x*0.05 > 50 ? x*0.05 : 50}
    BEGIN {print (h1-b1 > t(b1) && h2-b2 > t(b2)) ? 1 : 0}')
  printf '%-5s base %7.0f ms  branch %7.0f ms  delta %+6.0f ms%s\n' "$m" "$bm" "$hm" "$(awk -v a="$bm" -v b="$hm" 'BEGIN {print b-a}')" \
    "$([ "$slow" = 1 ] && echo '  SLOWER in both rounds')"
  [ "$slow" = 1 ] && fail=1
done
exit "$fail"
