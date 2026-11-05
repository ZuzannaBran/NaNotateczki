#!/usr/bin/env bash
# Read-only local verification of stage 3. Does not invoke GitHub Actions.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v dart >/dev/null 2>&1 ||
   ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter and Dart SDK are required; no tests have been run." >&2
  exit 2
fi

echo "[stage3] Format check (without modifying files)"
dart format --output=none --set-exit-if-changed \
  lib/data/drift/notes_database.dart \
  lib/data/drift/operation_schema.dart \
  lib/data/sync/editor_sqlite_projector.dart \
  lib/data/sync/editor_v2_account_runtime.dart \
  lib/data/sync/persistent_operation_actor.dart \
  lib/features/editor/state/editor_controller.dart \
  lib/features/editor/state/editor_v2_operation_writer.dart \
  lib/features/notebook/data/notebook_repository.dart \
  lib/features/library/presentation/library_screen.dart \
  lib/app/app_scope.dart \
  lib/features/editor/state/editor_v2_remote_patch_dispatcher.dart \
  lib/features/editor/presentation/widgets/page_overlay.dart \
  test/editor_controller_v2_test.dart \
  test/editor_sqlite_projector_test.dart \
  test/editor_v2_operation_writer_test.dart \
  test/editor_v2_remote_patch_dispatcher_test.dart \
  test/editor_v2_crash_recovery_test.dart \
  test/persistent_operation_actor_test.dart \
  test/verified_quill_embed_builder_test.dart \
  test/notebook_repository_v2_account_test.dart

echo "[stage3] Dart static analysis"
dart analyze

echo "[stage3] Focused v2 regression tests"
flutter test --concurrency=1 \
  test/operation_store_test.dart \
  test/persistent_operation_actor_test.dart \
  test/sync_engine_test.dart \
  test/editor_controller_v2_test.dart \
  test/editor_sqlite_projector_test.dart \
  test/editor_v2_operation_writer_test.dart \
  test/editor_v2_remote_patch_dispatcher_test.dart \
  test/editor_v2_crash_recovery_test.dart \
  test/verified_quill_embed_builder_test.dart \
  test/notebook_repository_v2_account_test.dart

echo "[stage3] Full unit and widget test suite"
flutter test --concurrency=2
echo "[stage3] All local tests passed."
