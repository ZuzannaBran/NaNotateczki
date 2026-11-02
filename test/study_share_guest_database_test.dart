import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/share/presentation/study_share_memory_db_stub.dart'
    if (dart.library.js_interop) 'package:program/features/share/presentation/study_share_memory_db_web.dart'
    as guest_db;

void main() {
  test('guest WASM database opens, saves data and remains isolated', () async {
    final first = await guest_db.openSharedGuestDatabase();
    try {
      await first.customStatement(
        'CREATE TABLE share_vfs_regression (value TEXT NOT NULL)',
      );
      await first.customStatement(
        'INSERT INTO share_vfs_regression (value) VALUES (?)',
        ['guest-change'],
      );
      final row = await first
          .customSelect('SELECT value FROM share_vfs_regression')
          .getSingle();
      expect(row.read<String>('value'), 'guest-change');

      final second = await guest_db.openSharedGuestDatabase();
      try {
        final otherRows = await second
            .customSelect(
              "SELECT name FROM sqlite_master "
              "WHERE name = 'share_vfs_regression'",
            )
            .get();
        expect(otherRows, isEmpty);
      } finally {
        await second.close();
      }
    } finally {
      await first.close();
    }
  }, skip: !kIsWeb);
}
