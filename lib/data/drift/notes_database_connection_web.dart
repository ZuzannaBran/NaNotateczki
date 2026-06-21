import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:flutter/foundation.dart';
import 'package:sqlite3/wasm.dart';

class NotesDatabaseConnection {
  NotesDatabaseConnection({required this.executor, required this.freshFile});

  final QueryExecutor executor;
  final bool freshFile;
}

Future<NotesDatabaseConnection> openNotesDatabaseConnection(String name) async {
  debugPrint('[web-db] loading sqlite3.wasm');
  final sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  debugPrint('[web-db] opening IndexedDB');
  final fileSystem = await IndexedDbFileSystem.open(dbName: name);
  debugPrint('[web-db] IndexedDB opened');
  final freshFile = fileSystem.xAccess('/database', 0) == 0;
  sqlite3.registerVirtualFileSystem(fileSystem, makeDefault: true);
  final executor = WasmDatabase(
    sqlite3: sqlite3,
    path: '/database',
    fileSystem: fileSystem,
  );
  debugPrint('[web-db] Drift executor ready');
  return NotesDatabaseConnection(executor: executor, freshFile: freshFile);
}
