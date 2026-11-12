#!/usr/bin/env bash
set -euo pipefail

# Cold Xcode builds can consume several minutes before Flutter executes cases.
ios_timeout="$(awk '
  /^  ios-simulator:/ { in_ios = 1 }
  in_ios && /name: Run all iOS integration cases in a single app process/ {
    getline
    gsub(/[^0-9]/, "", $0)
    print $0
    exit
  }
' .github/workflows/cross_platform_tests.yml)"
if [[ ! "$ios_timeout" =~ ^[0-9]+$ ]] || (( ios_timeout < 30 )); then
  echo 'iOS integration timeout must allow at least 30 minutes.' >&2
  exit 1
fi

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
cat > "$sandbox/flutter" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TRACE_FILE"
exit "${MOCK_STATUS:-0}"
MOCK
chmod +x "$sandbox/flutter"
export PATH="$sandbox:$PATH"
export TRACE_FILE="$sandbox/calls"

if bash .github/scripts/ios_integration_matrix.sh; then
  echo 'A missing UDID must not launch Flutter.' >&2
  exit 1
fi
test ! -e "$TRACE_FILE"

for suite in bootstrap.main documents.main pointer.main; do
  grep -Fq "$suite" integration_test/native_platform_matrix_test.dart
done

bash .github/scripts/ios_integration_matrix.sh 'device-123'
test "$(wc -l < "$TRACE_FILE")" -eq 1
grep -Fx 'test integration_test/native_platform_matrix_test.dart -d device-123 --dart-define=NANOTATECZKI_ISOLATED_CI=true --reporter expanded --timeout 3m' "$TRACE_FILE"

export MOCK_STATUS=23
if bash .github/scripts/ios_integration_matrix.sh device-123; then
  echo 'Flutter test failure must propagate to CI.' >&2
  exit 1
fi
test "$(wc -l < "$TRACE_FILE")" -eq 2
python3 .github/scripts/test_ios_integration_watchdog.py
echo 'Single-process iOS integration matrix contract passed.'
