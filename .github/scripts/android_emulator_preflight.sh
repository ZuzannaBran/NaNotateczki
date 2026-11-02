#!/usr/bin/env bash
set -euo pipefail

df -h "$HOME"
available_mb="$(df -Pm "$HOME" | awk 'NR == 2 {print $4}')"
if (( available_mb < 2000 )); then
  echo "::error::Only ${available_mb} MB free for a 1536M Android emulator."
  exit 1
fi
