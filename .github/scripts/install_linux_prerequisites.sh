#!/usr/bin/env bash
# Native Ubuntu dependencies with bounded retries and Canonical-independent
# signed mirrors. Never report a missing package as an accepted CI test.
set -euo pipefail

if (( $# == 0 )); then
  echo "Usage: $0 <ubuntu-package>..." >&2
  exit 2
fi

for package in "$@"; do
  if [[ ! "$package" =~ ^[a-z0-9][a-z0-9.+-]*$ ]]; then
    echo "Invalid Ubuntu package name: $package" >&2
    exit 2
  fi
done

missing=()
for package in "$@"; do
  if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
    grep -qx 'install ok installed'; then
    missing+=("$package")
  fi
done
if (( ${#missing[@]} == 0 )); then
  echo "All required Ubuntu packages are already installed."
  exit 0
fi

codename="${NN_UBUNTU_CODENAME:-$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")}"
if [[ ! "$codename" =~ ^[a-z]+$ ]]; then
  echo "Invalid Ubuntu release codename." >&2
  exit 2
fi

keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
if [[ ! -f "$keyring" ]]; then
  echo "Ubuntu archive signing keyring is missing." >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
sources="$workdir/sources.list"
apt_args=(
  -o "Dir::Etc::sourcelist=$sources"
  -o "Dir::Etc::sourceparts=-"
  -o "APT::Update::Error-Mode=any"
  -o "Acquire::Retries=0"
  -o "Acquire::http::Timeout=12"
  -o "Acquire::https::Timeout=12"
  -o "Acquire::ForceIPv4=true"
)

# Ubuntu's signed archive is replicated to independent HTTPS hosts.
# Do not use the runner's mirror+file list: it points at the degraded
# Canonical/Azure DNS infrastructure and can stall for over an hour.
mirrors=(
  https://mirrors.seas.harvard.edu/ubuntu
  https://mirrors.edge.kernel.org/ubuntu
)
for mirror in "${mirrors[@]}"; do
  printf 'deb [signed-by=%s] %s %s %s\n' \
    "$keyring" "$mirror" "$codename" \
    "main restricted universe multiverse" > "$sources"
  printf 'deb [signed-by=%s] %s %s-updates %s\n' \
    "$keyring" "$mirror" "$codename" \
    "main restricted universe multiverse" >> "$sources"
  echo "Installing ${missing[*]} using signed Ubuntu archive: $mirror"
  if timeout -k 5s 95s sudo -n apt-get "${apt_args[@]}" update &&
    timeout -k 5s 170s sudo -n apt-get "${apt_args[@]}" install \
      --no-install-recommends -y "${missing[@]}"; then
    for package in "${missing[@]}"; do
      dpkg-query -W -f='${Status}' "$package" |
        grep -qx 'install ok installed' || {
          echo "Ubuntu package did not install: $package" >&2
          exit 1
        }
    done
    exit 0
  fi
  echo "::warning::Ubuntu mirror failed: $mirror; trying next source."
done

echo "::error::Unable to install verified native dependencies." >&2
exit 1
