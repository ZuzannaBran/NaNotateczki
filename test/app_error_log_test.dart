import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/error/app_error_log.dart';
import 'package:program/core/storage/text_storage.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('repeated errors are grouped without hiding other errors', () async {
    final log = AppErrorLog.instance;
    log.clear();
    addTearDown(log.clear);
    final stack = StackTrace.fromString('same-stack');

    for (var index = 0; index < 90; index++) {
      log.record(StateError('folder metadata'), stack, source: 'backup');
    }

    expect(log.length, 1);
    expect(log.entries.single.occurrences, 90);
    expect(log.toClipboardText(), contains('(x90)'));

    log.record(StateError('other error'), stack, source: 'editor');

    expect(log.length, 2);
    expect(log.entries.first.source, 'editor');
    expect(log.entries.last.occurrences, 90);

    // Pending saves must settle before the isolated test directory is removed.
    await waitForPendingTextStorageOperations();
    final stored = await readStoredText('app_error_log.json');
    expect(stored, isNotNull);
    final entries = jsonDecode(stored!) as List<dynamic>;
    expect(entries, hasLength(2));
    expect((entries.last as Map<String, dynamic>)['occurrences'], 90);
  });

  test('entry serialization keeps counts and accepts legacy logs', () {
    final original = AppErrorLogEntry(
      occurredAt: DateTime.utc(2026, 10, 16),
      source: 'backup',
      error: 'folder metadata',
      stackTrace: 'same-stack',
      occurrences: 12,
    );
    final decoded = AppErrorLogEntry.fromJson(original.toJson());

    expect(decoded?.occurrences, 12);
    expect(decoded?.format(), contains('(x12)'));

    final oldEntry = AppErrorLogEntry.fromJson({
      'occurredAt': '2026-10-16T13:00:00.000',
      'source': 'backup',
      'error': 'legacy format',
      'stackTrace': null,
    });
    expect(oldEntry?.occurrences, 1);
  });
}
