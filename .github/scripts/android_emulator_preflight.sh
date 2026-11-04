#!/usr/bin/env bash
set -euo pipefail

# Emulator 37 needs more than the AVD's configured 1536M userdata size.
# Fail before the five-minute ADB boot timeout if the runner is too full.
minimum_mb=8700

free_mb() {
  df -Pm "$HOME" | awk 'NR == 2 {print $4}'
}

available_mb="$(free_mb)"
echo "Android emulator disk: ${available_mb} MB free (minimum ${minimum_mb} MB)."

if (( available_mb < minimum_mb )); then
  # The emulator job never uses Docker containers or images.
  if command -v docker >/dev/null 2>&1; then
    if ! docker system prune --all --force --volumes; then
      echo "::warning::Could not reclaim unused Docker data."
    fi
  fi
  available_mb="$(free_mb)"
fi

if (( available_mb < minimum_mb )); then
  # Keep the installed API-35 system image used by this job. Other emulator
  # images do not participate in the current test.
  sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -n "$sdk_root" && -d "$sdk_root/system-images" ]]; then
    for image in "$sdk_root"/system-images/*; do
      if [[ -d "$image" && ! -L "$image" && "${image##*/}" != android-35 ]]; then
        echo "Removing unused Android emulator image: ${image##*/}"
        sudo rm -rf -- "$image"
      fi
    done
  fi
  available_mb="$(free_mb)"
fi

df -h "$HOME"
if (( available_mb < minimum_mb )); then
  echo "::error::Insufficient emulator space after safe cleanup: ${available_mb} MB; need at least ${minimum_mb} MB."
  exit 1
fi
