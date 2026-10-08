#!/bin/bash
# Simulator video (left) beside the rendered agent panel (right): compose.sh <sim.mov> <framesdir> <out.mp4> [lead]
# lead: seconds the recording started before the agent (the panel waits that long). The simulator recording stops
# at its last screen change, so its last frame is held until the panel ends.
set -euo pipefail
SIM=$1 FRAMES=$2 OUT=$3 LEAD=${4:-0}
ffmpeg -y -loglevel error -f concat -safe 0 -i "$FRAMES/frames.txt" -vf "fps=30,format=yuv420p" "$FRAMES/panel.mp4"
ffmpeg -y -loglevel error -i "$SIM" -i "$FRAMES/panel.mp4" -filter_complex \
  "[0:v]scale=-2:874,setsar=1,fps=30,tpad=stop_mode=clone:stop_duration=3600[l];[1:v]scale=-2:874,setsar=1,tpad=start_duration=$LEAD:color=0x141414[r];[l][r]hstack=inputs=2:shortest=1,format=yuv420p" \
  -c:v libx264 -crf 23 -movflags +faststart "$OUT"
echo "$OUT"
