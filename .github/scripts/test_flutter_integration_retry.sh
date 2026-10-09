#!/usr/bin/env bash
set -euo pipefail

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
cat > "$work_dir/flutter" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$TEST_ATTEMPT_FILE" ]]; then
  count="$(cat "$TEST_ATTEMPT_FILE")"
fi
count=$((count + 1))
echo "$count" > "$TEST_ATTEMPT_FILE"
if [[ "$TEST_SCENARIO" == "dds" && "$count" == 1 ]]; then
  echo "Failed to start Dart Development Service" >&2
  exit 1
fi
if [[ "$TEST_SCENARIO" == "assertion" ]]; then
  echo "Expected 2, got 3" >&2
  exit 1
fi
if [[ "$TEST_SCENARIO" == "persistent_dds" ]]; then
  echo "Failed to start Dart Development Service" >&2
  exit 1
fi
echo "All tests passed!"
MOCK
chmod +x "$work_dir/flutter"
export PATH="$work_dir:$PATH"
export DDS_RETRY_DELAY_SECONDS=0
export TEST_ATTEMPT_FILE="$work_dir/attempts"

export TEST_SCENARIO=dds
bash .github/scripts/flutter_integration_retry.sh integration_test/app_smoke_test.dart
test "$(cat "$TEST_ATTEMPT_FILE")" -eq 2

rm "$TEST_ATTEMPT_FILE"
export TEST_SCENARIO=assertion
if bash .github/scripts/flutter_integration_retry.sh integration_test/app_smoke_test.dart; then
  echo "An assertion failure was incorrectly accepted." >&2
  exit 1
fi
test "$(cat "$TEST_ATTEMPT_FILE")" -eq 1

rm "$TEST_ATTEMPT_FILE"
export TEST_SCENARIO=persistent_dds
if bash .github/scripts/flutter_integration_retry.sh integration_test/app_smoke_test.dart; then
  echo "Persistent DDS failures were incorrectly accepted." >&2
  exit 1
fi
test "$(cat "$TEST_ATTEMPT_FILE")" -eq 2
echo "DDS retry regression tests passed."
