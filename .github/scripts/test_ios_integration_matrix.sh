#!/usr/bin/env bash
set -euo pipefail

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
echo 'Single-process iOS integration matrix contract passed.'
