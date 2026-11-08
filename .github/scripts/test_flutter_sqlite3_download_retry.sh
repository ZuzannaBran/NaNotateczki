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
if [[ "$TEST_SCENARIO" == "hash" && "$count" == 1 ]]; then
  echo 'Bad state: Hash of downloaded file libsqlite3.x64.linux.so is changed, expected original' >&2
  exit 1
fi
if [[ "$TEST_SCENARIO" == "assertion" ]]; then
  echo 'Expected 2, got 3' >&2
  exit 1
fi
if [[ "$TEST_SCENARIO" == "persistent_hash" ]]; then
  echo 'Bad state: Hash of downloaded file libsqlite3.x64.linux.so is changed, expected original' >&2
  exit 1
fi
echo 'All tests passed!'
MOCK
chmod +x "$work_dir/flutter"
export PATH="$work_dir:$PATH"
export TEST_ATTEMPT_FILE="$work_dir/attempts"

export TEST_SCENARIO=hash
bash .github/scripts/flutter_sqlite3_download_retry.sh --platform chrome
test "$(cat "$TEST_ATTEMPT_FILE")" -eq 2

rm "$TEST_ATTEMPT_FILE"
export TEST_SCENARIO=assertion
if bash .github/scripts/flutter_sqlite3_download_retry.sh --platform chrome; then
  echo "A genuine test failure was incorrectly accepted." >&2
  exit 1
fi
test "$(cat "$TEST_ATTEMPT_FILE")" -eq 1

rm "$TEST_ATTEMPT_FILE"
export TEST_SCENARIO=persistent_hash
if bash .github/scripts/flutter_sqlite3_download_retry.sh --platform chrome; then
  echo "Persistent hash mismatch was incorrectly accepted." >&2
  exit 1
fi
test "$(cat "$TEST_ATTEMPT_FILE")" -eq 2
echo "sqlite3 download retry regression tests passed."
