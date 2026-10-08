#!/bin/bash
# Formats every Swift file with the repo's .swift-format (M4a spec §4). Usage: scripts/format.sh
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift-format format -i -r --configuration .swift-format Sources Tests
