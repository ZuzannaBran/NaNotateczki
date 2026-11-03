import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/live_web_sync_service.dart';
import 'package:program/features/share/presentation/study_share_guest_editor.dart';

void main() {
  test(
    'shared canvases do not publish a full snapshot for every local save',
    () {
      expect(
        sharedDocumentSyncDebounce,
        greaterThanOrEqualTo(const Duration(milliseconds: 100)),
      );
      expect(
        sharedGuestPushDebounce,
        greaterThanOrEqualTo(const Duration(milliseconds: 100)),
      );
    },
  );
}
