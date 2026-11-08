#!/usr/bin/env bash
set -euo pipefail

device="${1:-}"
if [[ -z "$device" || "$#" -ne 1 ]]; then
  echo 'Exactly one iOS simulator UDID is required.' >&2
  exit 2
fi

flutter test integration_test/native_platform_matrix_test.dart \
  -d "$device" \
  --dart-define=NANOTATECZKI_ISOLATED_CI=true \
  --reporter expanded --timeout 3m
