import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/sync/study_share_guest_outbox.dart';

void main() {
  final storage = <String, String>{};

  setUp(() {
    storage.clear();
    textStorageReadOverride = (key) async => storage[key];
    textStorageWriteOverride = (key, value) async {
      storage[key] = value;
    };
  });
  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('guest edits survive reload, are isolated and clear on ack', () async {
    const base = <String, dynamic>{
      'uid': 'original', 'pages': <Map<String, dynamic>>[],
    };
    const changed = <String, dynamic>{
      'uid': 'original',
      'pages': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'stroke'},
      ],
    };
    final first = StudyShareGuestOutbox('session-a');
    await first.write(const PendingStudyShareEdit(
      baseRevision: 4,
      baseNotebook: base,
      notebook: changed,
    ));

    final reopened = await StudyShareGuestOutbox('session-a').read();
    expect(reopened, isNotNull);
    expect(reopened!.baseRevision, 4);
    expect(reopened.baseNotebook, base);
    expect(reopened.notebook, changed);
    expect(await StudyShareGuestOutbox('session-b').read(), isNull);
    await first.clear();
    expect(await first.read(), isNull);
  });

  test('mismatched document identifiers reject forged recovery', () async {
    final outbox = StudyShareGuestOutbox('session-a');
    await outbox.write(const PendingStudyShareEdit(
      baseRevision: 1,
      baseNotebook: {'uid': 'owner', 'pages': []},
      notebook: {'uid': 'other', 'pages': []},
    ));
    await expectLater(outbox.read(), throwsFormatException);
  });

  test('malformed snapshots are never silently accepted', () async {
    final outbox = StudyShareGuestOutbox('session-a');
    storage['study_share_guest_outbox_v1_session-a'] = '{"version":1}';
    await expectLater(outbox.read(), throwsFormatException);
    storage['study_share_guest_outbox_v1_session-a'] = 'not-json';
    await expectLater(outbox.read(), throwsFormatException);
  });
}
