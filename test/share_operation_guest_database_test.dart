import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/features/share/presentation/study_share_memory_db_stub.dart'
    if (dart.library.js_interop) 'package:program/features/share/presentation/study_share_memory_db_web.dart'
    as guest_db;

void main() {
  test('guest operation outbox survives reload without leaking to other share',
      () async {
    final firstShare = const Uuid().v4();
    final secondShare = const Uuid().v4();
    final first = await guest_db.openSharedGuestOperationDatabase(firstShare);
    String? operationId;
    try {
      final store = OperationStore(first);
      final operation = await store.writeLocal(
        actorId: 'guest',
        documentId: 'shared-doc',
        kind: OperationKind.documentCreate,
        payload: {
          'value': {'title': 'Only in guest A'},
        },
        apply: (_) async {},
      );
      operationId = operation.operationId;
      expect(await store.pending(), hasLength(1));
    } finally {
      await first.close();
    }

    final restored = await guest_db.openSharedGuestOperationDatabase(firstShare);
    try {
      final entries = await OperationStore(restored).pending();
      expect(entries.map((entry) => entry.operationId),
          contains(operationId));
    } finally {
      await restored.close();
    }

    final isolated = await guest_db.openSharedGuestOperationDatabase(secondShare);
    try {
      expect(await OperationStore(isolated).pending(), isEmpty);
    } finally {
      await isolated.close();
    }
  }, skip: !kIsWeb);
}
