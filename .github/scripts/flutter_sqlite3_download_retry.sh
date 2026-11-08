#!/usr/bin/env bash
set -euo pipefail

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

if flutter test "$@" 2>&1 | tee "$log_file"; then
  exit 0
fi

# Re-try a transient sqlite3 download only; never bypass the hash check.
if ! grep -Fq 'Hash of downloaded file libsqlite3.' "$log_file"; then
  exit 1
fi

echo "::warning::sqlite3 native binary checksum mismatch; retrying once." >&2
flutter test "$@"
