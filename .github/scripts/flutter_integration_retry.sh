#!/usr/bin/env bash
set -euo pipefail

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

if flutter test "$@" 2>&1 | tee "$log_file"; then
  exit 0
fi

if ! grep -Fq 'Failed to start Dart Development Service' "$log_file"; then
  exit 1
fi

echo "Dart Development Service startup failed; retrying once." >&2
sleep "${DDS_RETRY_DELAY_SECONDS:-8}"
flutter test "$@"
