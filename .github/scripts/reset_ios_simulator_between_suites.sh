#!/usr/bin/env bash
set -euo pipefail

udid="${1:-}"
if [[ -z "$udid" ]]; then
  echo 'Simulator UDID is required before restarting a test suite.' >&2
  exit 2
fi

# A fresh boot releases the previous Flutter runner and VM service.
xcrun simctl shutdown "$udid"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
