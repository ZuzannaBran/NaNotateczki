#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin"

cat > "$sandbox/bin/df" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-Pm" ]]; then
  printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n'
  printf '/dev/test 50000 44000 %s 88%% /home/runner\n' "$(cat "$FAKE_FREE_FILE")"
else
  echo 'Fake preflight filesystem'
fi
MOCK

cat > "$sandbox/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DOCKER_CALLS"
if [[ -n "${FAKE_AFTER_PRUNE_MB:-}" ]]; then
  printf '%s\n' "$FAKE_AFTER_PRUNE_MB" > "$FAKE_FREE_FILE"
fi
MOCK
chmod +x "$sandbox/bin/df" "$sandbox/bin/docker"

export PATH="$sandbox/bin:$PATH"
export ANDROID_HOME=''
export ANDROID_SDK_ROOT=''
export FAKE_FREE_FILE="$sandbox/available"
export FAKE_DOCKER_CALLS="$sandbox/docker"

printf '10000\n' > "$FAKE_FREE_FILE"
bash "$repo_root/.github/scripts/android_emulator_preflight.sh"
test ! -s "$FAKE_DOCKER_CALLS"

printf '6000\n' > "$FAKE_FREE_FILE"
export FAKE_AFTER_PRUNE_MB=10000
bash "$repo_root/.github/scripts/android_emulator_preflight.sh"
grep -qx 'system prune --all --force --volumes' "$FAKE_DOCKER_CALLS"

: > "$FAKE_DOCKER_CALLS"
printf '6000\n' > "$FAKE_FREE_FILE"
unset FAKE_AFTER_PRUNE_MB
if bash "$repo_root/.github/scripts/android_emulator_preflight.sh"; then
  echo 'Preflight must reject unrecoverably full runners.' >&2
  exit 1
fi
grep -qx 'system prune --all --force --volumes' "$FAKE_DOCKER_CALLS"

echo 'Android emulator preflight regression cases passed.'
