#!/usr/bin/env bash
set -euo pipefail

temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
cat > "$temp/mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$ATTEMPT_FILE" ]]; then
  count="$(cat "$ATTEMPT_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$ATTEMPT_FILE"
case "$SCENARIO" in
  checksum)
    if (( count == 1 )); then
      echo 'Bad state: Hash of downloaded file libsqlite3.x64.linux.so is wrong' >&2
      exit 1
    fi
    ;;
  gateway)
    if (( count < 3 )); then
      echo 'Server returned HTTP response code: 504 for URL: test' >&2
      exit 1
    fi
    ;;
  persistent)
    echo 'Bad state: Hash of downloaded file libsqlite3.x64.linux.so is wrong' >&2
    exit 1
    ;;
  assertion)
    echo 'Expected 2, got 3' >&2
    exit 1
    ;;
  *)
    exit 99
    ;;
esac
printf 'Passed after %s attempts\n' "$count"
MOCK
chmod +x "$temp/mock"
export ATTEMPT_FILE="$temp/attempt"
export SCENARIO=checksum
bash .github/scripts/flutter_transient_network_retry.sh "$temp/mock" build apk
test "$(cat "$ATTEMPT_FILE")" -eq 2

rm "$ATTEMPT_FILE"
export SCENARIO=gateway
bash .github/scripts/flutter_transient_network_retry.sh "$temp/mock" build apk
test "$(cat "$ATTEMPT_FILE")" -eq 3

rm "$ATTEMPT_FILE"
export SCENARIO=persistent
if bash .github/scripts/flutter_transient_network_retry.sh "$temp/mock"; then
  echo 'Persistent checksum failure was swallowed.' >&2
  exit 1
fi
test "$(cat "$ATTEMPT_FILE")" -eq 3

rm "$ATTEMPT_FILE"
export SCENARIO=assertion
if bash .github/scripts/flutter_transient_network_retry.sh "$temp/mock"; then
  echo 'An assertion failure was swallowed.' >&2
  exit 1
fi
test "$(cat "$ATTEMPT_FILE")" -eq 1

if bash .github/scripts/flutter_transient_network_retry.sh; then
  echo 'The retry wrapper must reject an empty command.' >&2
  exit 1
fi
# Keep CI off the GitHub Release redirect that returned HTTP 504.
grep -Fq 'distributionUrl=https\://downloads.gradle.org/distributions/gradle-8.14-all.zip' \
  android/gradle/wrapper/gradle-wrapper.properties
# The release compile has to be unsigned on an unprovisioned macOS runner.
grep -Fq 'CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO' \
  .github/workflows/cross_platform_tests.yml
echo 'Native download and unsigned release CI contract passed.'
