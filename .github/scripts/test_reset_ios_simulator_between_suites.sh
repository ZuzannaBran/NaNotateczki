#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/xcrun" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SIMCTL_CALLS"
MOCK
chmod +x "$scratch/xcrun"
export PATH="$scratch:$PATH"
export SIMCTL_CALLS="$scratch/calls"

if bash .github/scripts/reset_ios_simulator_between_suites.sh; then
  echo 'A missing simulator ID must fail before shutdown.' >&2
  exit 1
fi
test ! -e "$SIMCTL_CALLS"

bash .github/scripts/reset_ios_simulator_between_suites.sh 'test-device-id'
printf 'simctl shutdown test-device-id\nsimctl boot test-device-id\nsimctl bootstatus test-device-id -b\n' > "$scratch/expected"
diff -u "$scratch/expected" "$SIMCTL_CALLS"
echo 'iOS simulator restart regression passed.'
