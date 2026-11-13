import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> assertTaskTombstone(OperationStore store) async {
    final created = await store.writeLocal(
      actorId: 'task-test-actor',
      documentId: OperationEnvelope.libraryDocumentId,
      objectId: 'task-one',
      kind: OperationKind.taskCreate,
      payload: const {
        'value': {'plannerUid': 'planner-1', 'title': 'A'},
      },
      apply: (_) async {},
    );
    final deleted = await store.writeLocal(
      actorId: 'task-test-actor',
      documentId: OperationEnvelope.libraryDocumentId,
      objectId: 'task-one',
      kind: OperationKind.taskDelete,
      payload: const {},
      apply: (_) async {},
    );
    expect(deleted.dependencies, contains(created.operationId));
    expect(
      await store.isTombstoned(
        OperationEnvelope.libraryDocumentId,
        'task',
        'task-one',
      ),
      isTrue,
    );
    await expectLater(
      store.writeLocal(
        actorId: 'task-test-actor',
        documentId: OperationEnvelope.libraryDocumentId,
        objectId: 'task-one',
        kind: OperationKind.taskCreate,
        payload: const {
          'value': {'plannerUid': 'planner-1', 'title': 'Resurrected'},
        },
        apply: (_) async {},
      ),
      throwsStateError,
    );
    final afterFailure = await store.writeLocal(
      actorId: 'task-test-actor',
      documentId: OperationEnvelope.libraryDocumentId,
      objectId: 'task-two',
      kind: OperationKind.taskCreate,
      payload: const {
        'value': {'plannerUid': 'planner-1', 'title': 'B'},
      },
      apply: (_) async {},
    );
    expect(afterFailure.actorSeq, 3);
  }

  test('new SQLite journals preserve permanent task deletions', () async {
    final db = NotesDatabase(NativeDatabase.memory());
    try {
      await assertTaskTombstone(OperationStore(db));
    } finally {
      await db.close();
    }
  });

  test('v5 to v6 keeps previous tombstones and allows task delete', () async {
    final directory = await Directory.systemTemp.createTemp('task-v6-');
    final file = File('${directory.path}/notes.sqlite');
    var database = NotesDatabase(NativeDatabase(file));
    try {
      final store = OperationStore(database);
      await store.writeLocal(
        actorId: 'folder-test-actor',
        documentId: OperationEnvelope.libraryDocumentId,
        objectId: 'previous-folder',
        kind: OperationKind.folderCreate,
        payload: const {
          'value': {'name': 'Previous'},
        },
        apply: (_) async {},
      );
      await store.writeLocal(
        actorId: 'folder-test-actor',
        documentId: OperationEnvelope.libraryDocumentId,
        objectId: 'previous-folder',
        kind: OperationKind.folderDelete,
        payload: const {},
        apply: (_) async {},
      );
      await database.close();

      // Simulate the historic v5 CHECK constraint on the same file.
      final old = sqlite.sqlite3.open(file.path);
      try {
        old.execute('BEGIN');
        old.execute('''
          CREATE TABLE object_tombstones_v5 (
            document_id TEXT NOT NULL,
            target_kind TEXT NOT NULL
              CHECK(target_kind IN ('document', 'page', 'object', 'folder')),
            page_id TEXT NOT NULL DEFAULT '',
            object_id TEXT NOT NULL,
            operation_id TEXT NOT NULL
              REFERENCES operations(operation_id) ON DELETE RESTRICT,
            PRIMARY KEY(document_id, target_kind, page_id, object_id)
          )
        ''');
        old.execute('''
          INSERT INTO object_tombstones_v5
            SELECT document_id, target_kind, page_id, object_id, operation_id
            FROM object_tombstones
        ''');
        old.execute('DROP TABLE object_tombstones');
        old.execute(
          'ALTER TABLE object_tombstones_v5 RENAME TO object_tombstones',
        );
        old.execute('PRAGMA user_version=5');
        old.execute('COMMIT');
      } finally {
        old.close();
      }

      database = NotesDatabase(NativeDatabase(file));
      final upgraded = OperationStore(database);
      expect(
        await upgraded.isTombstoned(
          OperationEnvelope.libraryDocumentId,
          'folder',
          'previous-folder',
        ),
        isTrue,
      );
      await assertTaskTombstone(upgraded);
      expect(
        await upgraded.isTombstoned(
          OperationEnvelope.libraryDocumentId,
          'folder',
          'previous-folder',
        ),
        isTrue,
      );
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}
