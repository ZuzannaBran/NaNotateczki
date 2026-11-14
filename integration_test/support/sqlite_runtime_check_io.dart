import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:sqlite3/sqlite3.dart';

const supportsNativeSqliteRuntime = true;

Future<void> verifyNativeSqliteRuntime() async {
  if (Platform.isLinux) {
    final binary = File(Platform.resolvedExecutable);
    expect(
      File('${binary.parent.path}/lib/libsqlite3.so').existsSync(),
      isTrue,
      reason: 'The app must bundle the library named by the native hook.',
    );
  }
  final sqlite = sqlite3.openInMemory();
  try {
    expect(sqlite.select('SELECT sqlite_version()').single.values, isNotEmpty);
    expect(
      sqlite
          .select("SELECT json_extract('{\"value\":42}', '\$.value') AS value")
          .single['value'],
      42,
    );
    sqlite.execute('CREATE VIRTUAL TABLE search USING fts5(content)');
    sqlite.execute("INSERT INTO search VALUES ('native SQLite')");
    expect(
      sqlite.select("SELECT content FROM search WHERE search MATCH 'native'"),
      hasLength(1),
    );
  } finally {
    sqlite.close();
  }

  final directory = await Directory.systemTemp.createTemp('nn-native-abi-');
  final file = File('${directory.path}/notes.sqlite');
  try {
    for (var attempt = 0; attempt < 2; attempt++) {
      final database = NotesDatabase(NativeDatabase.createInBackground(file));
      try {
        if (attempt == 0) {
          await database.customStatement(
            'CREATE TABLE loader_probe (value INTEGER NOT NULL)',
          );
          await database.customStatement(
            'INSERT INTO loader_probe VALUES (42)',
          );
        }
        final row = await database
            .customSelect('SELECT value FROM loader_probe')
            .getSingle();
        expect(row.read<int>('value'), 42);
      } finally {
        await database.close();
      }
    }
  } finally {
    await directory.delete(recursive: true);
  }
}
