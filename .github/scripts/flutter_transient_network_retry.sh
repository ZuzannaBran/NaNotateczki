#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  echo 'A command is required.' >&2
  exit 2
fi

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

for attempt in 1 2 3; do
  if "$@" 2>&1 | tee "$log_file"; then
    exit 0
  fi

  # GitHub release downloads occasionally return a gateway error page
  # instead of the SQLite binary. Never disable checksum verification.
  if ! grep -Eq \
    'Hash of downloaded file libsqlite3\.|Server returned HTTP response code: 50[234]|HTTP (502|503|504)' \
    "$log_file"; then
    exit 1
  fi
  if (( attempt == 3 )); then
    echo "::error::Native dependency download failed after 3 attempts." >&2
    exit 1
  fi
  echo "::warning::Transient native dependency download failure; retry $((attempt + 1))/3." >&2
  sleep "$((attempt * 3))"
done
