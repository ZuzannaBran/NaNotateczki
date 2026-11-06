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
  lib/data/sync/editor_history_checkpoint.dart \
  lib/data/sync/editor_history_notebook_codec.dart \
  lib/data/sync/editor_history_store.dart \
  lib/data/sync/operation_store.dart \
  lib/data/sync/editor_sqlite_projector.dart \
  lib/data/sync/editor_v2_account_runtime.dart \
  lib/data/sync/persistent_operation_actor.dart \
  lib/data/sync/operation_asset_gateway.dart \
  lib/data/sync/sync_engine.dart \
  lib/data/sync/verified_editor_asset_buffer.dart \
  lib/features/editor/state/editor_controller.dart \
  lib/features/editor/state/editor_operation_bridge.dart \
  lib/features/editor/state/quill_style_patch.dart \
  lib/features/editor/state/quill_paste_plan.dart \
  lib/data/sync/share_text_edit_adapter.dart \
  lib/features/editor/state/editor_v2_operation_writer.dart \
  lib/features/notebook/data/notebook_repository.dart \
  lib/features/library/presentation/library_screen.dart \
  lib/app/app_scope.dart \
  lib/features/editor/state/editor_v2_remote_patch_dispatcher.dart \
  lib/features/editor/presentation/widgets/page_overlay.dart \
  lib/features/editor/presentation/widgets/text_edit_toolbar.dart \
  lib/features/editor/presentation/widgets/text_hud_block.dart \
  test/editor_history_checkpoint_test.dart \
  test/editor_history_notebook_codec_test.dart \
  test/editor_history_store_test.dart \
  test/editor_controller_v2_test.dart \
  test/editor_operation_bridge_test.dart \
  test/editor_v2_native_image_history_test.dart \
  test/quill_style_patch_test.dart \
  test/quill_paste_plan_test.dart \
  test/editor_v2_rich_paste_test.dart \
  test/editor_v2_inline_file_sync_test.dart \
  test/editor_sqlite_projector_test.dart \
  test/editor_v2_operation_writer_test.dart \
  test/editor_v2_remote_patch_dispatcher_test.dart \
  test/editor_v2_crash_recovery_test.dart \
  test/persistent_operation_actor_test.dart \
  test/verified_quill_embed_builder_test.dart \
  test/notebook_repository_v2_account_test.dart \
  test/library_v2_settings_test.dart \
  test/editor_v2_offline_media_test.dart \
  test/editor_v2_quill_asset_recovery_test.dart \
  test/page_overlay_v2_quill_edit_test.dart \
  test/operation_asset_gateway_test.dart

echo "[stage3] Dart static analysis"
dart analyze

echo "[stage3] Focused v2 regression tests"
flutter test --concurrency=1 \
  test/quill_style_patch_test.dart \
  test/quill_paste_plan_test.dart \
  test/editor_v2_rich_paste_test.dart \
  test/editor_v2_inline_file_sync_test.dart \
  test/operation_store_test.dart \
  test/persistent_operation_actor_test.dart \
  test/sync_engine_test.dart \
  test/editor_history_checkpoint_test.dart \
  test/editor_history_notebook_codec_test.dart \
  test/editor_history_store_test.dart \
  test/editor_controller_v2_test.dart \
  test/editor_operation_bridge_test.dart \
  test/editor_v2_native_image_history_test.dart \
  test/editor_sqlite_projector_test.dart \
  test/editor_v2_operation_writer_test.dart \
  test/editor_v2_remote_patch_dispatcher_test.dart \
  test/editor_v2_crash_recovery_test.dart \
  test/verified_quill_embed_builder_test.dart \
  test/notebook_repository_v2_account_test.dart \
  test/library_v2_settings_test.dart \
  test/editor_v2_offline_media_test.dart \
  test/editor_v2_quill_asset_recovery_test.dart \
  test/page_overlay_v2_quill_edit_test.dart \
  test/operation_asset_gateway_test.dart

echo "[stage3] Full unit and widget test suite"
flutter test --concurrency=2
echo "[stage3] All local tests passed."
