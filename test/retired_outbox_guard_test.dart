import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/sync/retired_outbox_guard.dart';

void main() {
  tearDown(() => textStorageReadOverride = null);

  test('fresh accounts start without requesting historical data', () async {
    final visited = <String>[];
    textStorageReadOverride = (key) async {
      visited.add(key);
      return null;
    };
    await requireEmptyRetiredOutbox('account-a');
    await requireEmptyRetiredOutbox('account-b');
    expect(visited.toSet(), hasLength(2));
    expect(visited, everyElement(startsWith('server_sync_state_')));
  });

  test(
    'retired deletion intent is preserved even without a notebook',
    () async {
      textStorageReadOverride = (_) async => '{"pending":["deleted-uid"]}';
      await expectLater(requireEmptyRetiredOutbox('account'), throwsStateError);
      textStorageReadOverride = (_) async => '{"pending":[]}';
      await requireEmptyRetiredOutbox('account');
    },
  );

  test('invalid retired outboxes cannot silently bypass the guard', () async {
    for (final raw in ['[]', '{}', '{"pending":"invalid"}', 'broken']) {
      textStorageReadOverride = (_) async => raw;
      await expectLater(
        requireEmptyRetiredOutbox('account'),
        throwsFormatException,
      );
    }
  });
}
