#!/bin/bash
# Records the simulator while an agent works, then renders the run beside it.
# Usage: demos/lib/agent-run.sh <workdir> <chauffeur|xcode|code> <model> <title> <prompt>
#   chauffeur  chauffeur's MCP tools only (as in dogfood/run.sh)
#   xcode      Xcode 27's MCP tools only, with Apple's device-interaction skill (as in dogfood/run.sh)
#   code       chauffeur plus Read, Edit, Write and Bash, working in <workdir> (the crash demo)
# Needs UDID. Writes <workdir>/sim.mov, run.jsonl, events.tsv, frames/ and out.mp4.
set -euo pipefail
W=$1 ARM=$2 MODEL=$3 TITLE=$4 PROMPT=$5
UDID=${UDID:?set UDID to the simulator to drive}
DEVICE=${DEVICE:-"iPhone, iOS simulator"}
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/demos/lib"
BIN="$REPO/.build/release/chauffeur"
mkdir -p "$W"
SYS="You are driving an iOS Simulator for the user: $DEVICE, UDID $UDID. It is already booted."
case "$ARM" in
  chauffeur|code)
    MCP="$W/mcp.json"
    printf '{"mcpServers":{"chauffeur":{"command":"%s","args":["mcp"],"env":{"CHAUFFEUR_UDID":"%s"}}}}' "$BIN" "$UDID" > "$MCP"
    if [ "$ARM" = chauffeur ]; then
      TOOLS=(--tools Read --allowedTools "mcp__chauffeur Read" --disallowedTools Bash Edit Write Glob Grep WebFetch WebSearch Agent NotebookEdit Skill)
    else
      TOOLS=(--tools "Read,Edit,Write,Bash" --allowedTools "mcp__chauffeur Read Edit Write Bash" --disallowedTools WebFetch WebSearch Agent NotebookEdit Skill)
    fi ;;
  xcode)
    MCP="$REPO/dogfood/xcode.mcp.json"
    xcrun mcp-server stop >/dev/null 2>&1 || true
    SYS="$SYS

You have already loaded Xcode's device-interaction skill and you are the subagent it describes: perform the device
interactions yourself. The skill:

$("$REPO/dogfood/xcode-skill.sh")"
    TOOLS=(--tools Read --allowedTools "mcp__xcode__DeviceInteractionStartSession mcp__xcode__DeviceInteractionStartWorkspaceSession mcp__xcode__XcodeListWorkspaces mcp__xcode__DeviceInteractionSynthesize mcp__xcode__DeviceInteractionEndSession mcp__xcode__GetConsoleOutput Read" --disallowedTools Bash Edit Write Glob Grep WebFetch WebSearch Agent NotebookEdit Skill) ;;
  *) echo "arm must be chauffeur, xcode or code" >&2; exit 2 ;;
esac
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$W/sim.mov" >/dev/null 2>&1 &
REC=$!
sleep 2
(cd "$W" && claude -p "$PROMPT" --model "$MODEL" --mcp-config "$MCP" --strict-mcp-config --setting-sources local \
   --append-system-prompt "$SYS" "${TOOLS[@]}" --max-budget-usd 2 --output-format stream-json --verbose < /dev/null \
   | python3 -I "$LIB/stamp.py" > "$W/run.jsonl") || true
sleep 1
kill -INT "$REC"; wait "$REC" 2>/dev/null || true
python3 -I "$LIB/events.py" "$W/run.jsonl" "$W/events.tsv"
"$REPO/scripts/check-public.sh" "$W/events.tsv"  # the panel is published as pixels, where no later check can see it
swift "$LIB/panel.swift" "$W/events.tsv" "$W/frames" 760 874 "$TITLE"
"$LIB/compose.sh" "$W/sim.mov" "$W/frames" "$W/out.mp4" 2  # recording starts 2 s before the agent
