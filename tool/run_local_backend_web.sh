#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

exec flutter run \
  -d chrome \
  --web-hostname localhost \
  --web-port 3000 \
  --dart-define=BACKEND_URL=http://localhost:18080 \
  "$@"
