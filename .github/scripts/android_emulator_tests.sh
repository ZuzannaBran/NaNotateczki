#!/usr/bin/env bash
set -euo pipefail

device="${ANDROID_EMULATOR_SERIAL:-emulator-5554}"

timeout 120 adb -s "$device" wait-for-device
timeout 180 adb -s "$device" shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
adb -s "$device" shell getprop sys.boot_completed | tr -d '\r' | grep -qx '1'

flutter test integration_test/app_smoke_test.dart -d "$device"
flutter test integration_test/document_lifecycle_test.dart -d "$device" \
  --dart-define=NANOTATECZKI_ISOLATED_CI=true
