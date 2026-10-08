#!/bin/bash
# Runs one dogfood task: dogfood/run.sh <task-id> <chauffeur|xcode> <model> <rep>
# The driving agent starts in an empty scratch dir with only one simulator tool set (plus Read for the files those
# tools write), no user/project settings, and a per-run budget cap.
set -euo pipefail
ID=$1 TOOL=$2 MODEL=$3 REP=$4
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/.build/release/chauffeur"
UDID=${UDID:?set UDID to the simulator to drive}
DEVICE=${DEVICE:-"iPhone 18 Pro, iOS 27.0"}
OUT="${RESULTS:-$REPO/dogfood/results}"
mkdir -p "$OUT"
RUN="$ID.$TOOL.$MODEL.$REP"
BUDGET=${BUDGET:-2.50}

load=$(sysctl -n vm.loadavg | awk '{print $2}')
if awk -v l="$load" 'BEGIN{exit !(l>20)}'; then echo "load $load > 20, refusing" >&2; exit 3; fi

line=$(awk -F'\t' -v id="$ID" '$1==id' "$REPO/dogfood/tasks.tsv")
[ -n "$line" ] || { echo "no task $ID" >&2; exit 2; }
RESET=$(cut -f2 <<<"$line"); PROMPT=$(cut -f3 <<<"$line")

q() { "$@" >/dev/null 2>&1 || true; }
# Xcode's device-interaction session switches these off when it ends; restore the pre-session state for every run.
# NO_AX_RESTORE=1 drops this crutch, so chauffeur has to recover on its own (M3a acceptance).
if [ -z "${NO_AX_RESTORE:-}" ]; then
  for k in ApplicationAccessibilityEnabled AutomationEnabled; do
    q xcrun simctl spawn $UDID defaults write com.apple.Accessibility $k -bool true
  done
fi
# Reset launches log to <run>.reset. A cold iOS 27 launch on this 8 GB host can outlast chauffeur's 5 s launch
# window, so the reset waits up to 30 s for the Home screen's "Show alert" row, and relaunches once if it never shows.
launch_fixture() {
  for attempt in 1 2; do
    "$BIN" --udid $UDID launch dev.chauffeur.fixture >> "$OUT/$RUN.reset" 2>&1 || true  # UNVERIFIED is fine: wait decides
    "$BIN" --udid $UDID wait "Show alert" --timeout 30 >> "$OUT/$RUN.reset" 2>&1 && return 0
    q "$BIN" --udid $UDID terminate dev.chauffeur.fixture
  done
  echo "reset: Fixture never showed its Home screen, see $RUN.reset" >&2; exit 5
}
: > "$OUT/$RUN.reset"
case "$RESET" in
  none) ;;
  fixture) q "$BIN" --udid $UDID terminate dev.chauffeur.fixture; launch_fixture ;;
  fixture-nolaunch) q "$BIN" --udid $UDID terminate dev.chauffeur.fixture; q "$BIN" --udid $UDID button home ;;
  settings) xcrun simctl ui $UDID appearance light; q "$BIN" --udid $UDID terminate com.apple.Preferences
            q "$BIN" --udid $UDID button home ;;
  perm) q xcrun simctl privacy $UDID reset location dev.chauffeur.fixture
        q "$BIN" --udid $UDID terminate dev.chauffeur.fixture; launch_fixture ;;
  calendar) q "$BIN" --udid $UDID terminate com.apple.mobilecal; q "$BIN" --udid $UDID button home ;;
  contacts) q "$BIN" --udid $UDID terminate com.apple.MobileAddressBook; q "$BIN" --udid $UDID button home ;;
  reminders) q "$BIN" --udid $UDID terminate com.apple.reminders; q "$BIN" --udid $UDID button home ;;
  *) echo "unknown reset $RESET" >&2; exit 2 ;;
esac
sleep 2

TRACE="${TMPDIR%/}/chauffeur/${UDID:0:8}.trace.jsonl"
[ -f "$TRACE" ] && : > "$TRACE"

case "$TOOL" in
  chauffeur) MCP=$(mktemp -t chauffeur-mcp).json
             printf '{"mcpServers":{"chauffeur":{"command":"%s","args":["mcp"],"env":{"CHAUFFEUR_UDID":"%s"}}}}' "$BIN" "$UDID" > "$MCP"
             ALLOW="mcp__chauffeur Read" ;;
  xcode) MCP="$REPO/dogfood/xcode.mcp.json"
         ALLOW="mcp__xcode__DeviceInteractionStartSession mcp__xcode__DeviceInteractionStartWorkspaceSession mcp__xcode__XcodeListWorkspaces mcp__xcode__DeviceInteractionSynthesize mcp__xcode__DeviceInteractionEndSession mcp__xcode__GetConsoleOutput Read" ;;
  *) echo "tool must be chauffeur or xcode" >&2; exit 2 ;;
esac

# Xcode device-interaction sessions outlive the agent that opened them and block new ones: start every run clean.
q xcrun mcp-server stop
SYS="You are driving an iOS Simulator for the user: $DEVICE, UDID $UDID. It is already booted."
# Apple documents DeviceInteractionSynthesize's command syntax only in Xcode's device-interaction skill
# (`xcrun mcpbridge run-agent skills export <dir>`), so the xcode arm starts with it loaded, as it would in Xcode.
if [ "$TOOL" = xcode ]; then
  SYS="$SYS

You have already loaded Xcode's device-interaction skill and you are the subagent it describes: perform the device
interactions yourself. The skill:

$("$REPO/dogfood/xcode-skill.sh")"
fi
SCRATCH=$(mktemp -d)
cd "$SCRATCH"
start=$(date +%s)
set +e
claude -p "$PROMPT" --model "$MODEL" \
  --mcp-config "$MCP" --strict-mcp-config --setting-sources local --tools Read \
  --append-system-prompt "$SYS" \
  --allowedTools $ALLOW \
  --disallowedTools Bash Edit Write Glob Grep WebFetch WebSearch Agent NotebookEdit Skill \
  --max-budget-usd "$BUDGET" \
  --output-format stream-json --verbose \
  < /dev/null > "$OUT/$RUN.jsonl" 2> "$OUT/$RUN.err"
rc=$?
set -e
echo "$RUN rc=$rc wall=$(( $(date +%s) - start ))s"
[ -f "$TRACE" ] && cp "$TRACE" "$OUT/$RUN.trace.jsonl" && : > "$TRACE"
xcrun simctl ui $UDID appearance > "$OUT/$RUN.appearance" 2>&1 || true
xcrun simctl io $UDID screenshot "$OUT/$RUN.png" >/dev/null 2>&1 || echo "end-state screenshot failed" >&2
rm -rf "$SCRATCH"
