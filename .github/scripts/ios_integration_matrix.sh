#!/usr/bin/env bash
set -euo pipefail

device="${1:-}"
if [[ -z "$device" || "$#" -ne 1 ]]; then
  echo 'Exactly one iOS simulator UDID is required.' >&2
  exit 2
fi

# Flutter 3.47 can lose the simulator VM-service log before attachment.
# Retry only that verified infrastructure stall, not failing test cases.
python3 .github/scripts/ios_integration_watchdog.py "$device"
