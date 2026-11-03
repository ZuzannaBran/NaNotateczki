import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NotesDatabase database;
  late OperationStore store;

  setUp(() async {
    database = NotesDatabase(NativeDatabase.memory());
    store = OperationStore(database);
    await database.customStatement(
      'CREATE TABLE projection_probe '
      '(id TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<OperationEnvelope> add(
    String objectId, {
    String actorId = 'device-one',
  }) {
    return store.writeLocal(
      actorId: actorId,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: objectId,
      kind: OperationKind.objectCreate,
      payload: {
        'properties': {'label': objectId},
      },
      apply: (_) => database.customStatement(
        'INSERT INTO projection_probe (id, value) VALUES (?, ?)',
        [objectId, objectId],
      ),
    );
  }

  test('projection and outbox share a transaction', () async {
    final first = await add('object-one');
    expect(first.actorSeq, 1);
    expect((await store.pending()).single.operationId, first.operationId);
    expect((await store.operation(first.operationId))?.actorSeq, 1);

    var retryCalled = false;
    expect(
      await store.commitLocal(
        first,
        apply: () async {
          retryCalled = true;
        },
      ),
      isFalse,
    );
    expect(retryCalled, isFalse);
    expect((await store.pending()).length, 1);
  });

  test('failed projection rolls back actor counter and outbox', () async {
    await expectLater(
      store.writeLocal(
        actorId: 'device-one',
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'lost-object',
        kind: OperationKind.objectCreate,
        payload: const {'properties': {}},
        apply: (_) async {
          await database.customStatement(
            'INSERT INTO projection_probe (id, value) VALUES (?, ?)',
            ['lost-object', 'temp'],
          );
          throw StateError('disk failure');
        },
      ),
      throwsStateError,
    );
    expect(await store.pending(), isEmpty);
    final rows = await database.customSelect(
      'SELECT * FROM projection_probe',
    ).get();
    expect(rows, isEmpty);
    expect((await add('safe-object')).actorSeq, 1);
  });

  test('local intent depends on every committed remote actor frontier',
      () async {
    final remote = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'actor-remote',
      actorSeq: 1,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'remote-observed',
      kind: OperationKind.objectCreate,
      payload: const {'properties': {}},
      dependencies: const [],
      logicalClock: 7,
    );
    await store.applyRemote(
      remote,
      checkpointScope: 'user-A-v2',
      serverSequence: 12,
      apply: () => database.customStatement(
        'INSERT INTO projection_probe VALUES (?, ?)',
        ['remote-observed', 'remote'],
      ),
    );

    final local = await add('local-after-remote');
    expect(local.dependencies, contains(remote.operationId));
    expect(local.logicalClock, greaterThan(remote.logicalClock));
  });

  test('stale remote edit after tombstone is logged but not projected',
      () async {
    await add('deleted-earlier');
    await store.writeLocal(
      actorId: 'device-one',
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'deleted-earlier',
      kind: OperationKind.objectDelete,
      payload: const {},
      apply: (_) => database.customStatement(
        'DELETE FROM projection_probe WHERE id = ?',
        ['deleted-earlier'],
      ),
    );
    final stale = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'actor-stale',
      actorSeq: 1,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'deleted-earlier',
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'label': 'must-not-appear'},
      },
      dependencies: const [],
      logicalClock: 1,
    );
    var projected = false;
    expect(
      await store.applyRemote(
        stale,
        checkpointScope: 'user-A-v2',
        serverSequence: 30,
        apply: () async {
          projected = true;
        },
      ),
      isTrue,
    );
    expect(projected, isFalse);
    expect(await store.checkpoint('user-A-v2'), 30);
    final rows = await database.customSelect(
      'SELECT * FROM projection_probe WHERE id = ?',
      variables: [const Variable<String>('deleted-earlier')],
    ).get();
    expect(rows, isEmpty);
  });

  test('ACK cannot erase unknown or mismatching operations', () async {
    final op = await add('object-ack');
    await expectLater(
      store.acknowledge(const Uuid().v4(), serverSequence: 3),
      throwsStateError,
    );
    expect(await store.pending(), hasLength(1));
    await store.acknowledge(op.operationId, serverSequence: 3);
    await store.acknowledge(op.operationId, serverSequence: 3);
    expect(await store.pending(), isEmpty);
    await expectLater(
      store.acknowledge(op.operationId, serverSequence: 4),
      throwsStateError,
    );
  });

  test('tombstones block reusing a deleted object ID', () async {
    await add('deleted-object');
    await store.writeLocal(
      actorId: 'device-one',
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'deleted-object',
      kind: OperationKind.objectDelete,
      payload: const {},
      apply: (_) => database.customStatement(
        'DELETE FROM projection_probe WHERE id = ?',
        ['deleted-object'],
      ),
    );
    expect(
      await store.isTombstoned(
        'document-one',
        'object',
        'deleted-object',
      ),
      isTrue,
    );
    await expectLater(add('deleted-object'), throwsStateError);
    expect((await add('new-identity')).actorSeq, 3);
  });

  test('failed remote apply never advances checkpoint', () async {
    final remote = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'other-device',
      actorSeq: 1,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'remote-object',
      kind: OperationKind.objectCreate,
      payload: const {'properties': {}},
      dependencies: const [],
      logicalClock: 1,
    );
    await expectLater(
      store.applyRemote(
        remote,
        checkpointScope: 'account-one',
        serverSequence: 7,
        apply: () async {
          throw StateError('projection rejected');
        },
      ),
      throwsStateError,
    );
    expect(await store.checkpoint('account-one'), 0);
    expect(await store.operation(remote.operationId), isNull);
    expect(
      await store.applyRemote(
        remote,
        checkpointScope: 'account-one',
        serverSequence: 7,
        apply: () => database.customStatement(
          'INSERT INTO projection_probe VALUES (?, ?)',
          ['remote-object', 'remote'],
        ),
      ),
      isTrue,
    );
    expect(await store.checkpoint('account-one'), 7);
    expect(
      await store.applyRemote(
        remote,
        checkpointScope: 'account-one',
        serverSequence: 7,
        apply: () async {
          throw StateError('duplicate replayed');
        },
      ),
      isFalse,
    );
  });

  test('snapshots are immutable and require acknowledged edits', () async {
    final first = await add('object-snapshot');
    await expectLater(
      store.saveSnapshot(
        documentId: 'document-one',
        serverSequence: 3,
        snapshotJson: '{"objects":1}',
      ),
      throwsStateError,
    );
    await store.acknowledge(first.operationId, serverSequence: 3);
    final saved = await store.saveSnapshot(
      documentId: 'document-one',
      serverSequence: 3,
      snapshotJson: '{"objects":1}',
    );
    expect((await store.latestSnapshot('document-one'))?.sha256,
        saved.sha256);
    await expectLater(
      store.saveSnapshot(
        documentId: 'document-one',
        serverSequence: 3,
        snapshotJson: '{"objects":0}',
      ),
      throwsStateError,
    );
  });

  test('same-document concurrent writes keep actor sequence', () async {
    final written = await Future.wait([
      for (var i = 0; i < 20; i++) add('object-$i'),
    ]);
    expect(written.map((operation) => operation.actorSeq),
        List<int>.generate(20, (index) => index + 1));
    expect(await store.pending(), hasLength(20));
  });

  test('v2 upgrades to v3 preserving legacy notebooks', () async {
    final folder = await Directory.systemTemp.createTemp('notes-drift-v3-');
    addTearDown(() => folder.delete(recursive: true));
    final file = File('${folder.path}/notes.sqlite');

    final initial = NotesDatabase(NativeDatabase(file));
    await initial.customSelect('SELECT 1').get();
    await initial.customStatement(
      'INSERT INTO notebook_rows '
      '(uid, title, kind_index, folder, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['preserved', 'Legacy notebook', 0, 'Notes', 100, 100],
    );
    await initial.close();

    final raw = sqlite.sqlite3.open(file.path);
    try {
      for (final table in [
        'operation_outbox',
        'operation_ack',
        'object_tombstones',
        'sync_checkpoints',
        'document_snapshots',
        'asset_references',
        'operation_actor_state',
        'operations',
      ]) {
        raw.execute('DROP TABLE IF EXISTS $table');
      }
      raw.execute('PRAGMA user_version = 2');
    } finally {
      raw.dispose();
    }

    final upgraded = NotesDatabase(NativeDatabase(file));
    try {
      final legacy = await upgraded.customSelect(
        'SELECT title FROM notebook_rows WHERE uid = ?',
        variables: [const Variable<String>('preserved')],
      ).getSingle();
      expect(legacy.read<String>('title'), 'Legacy notebook');
      final operations = await upgraded.customSelect(
        'SELECT name FROM sqlite_master '
        "WHERE type = 'table' AND name = 'operations'",
      ).getSingle();
      expect(operations.read<String>('name'), 'operations');
      expect(upgraded.schemaVersion, 3);
    } finally {
      await upgraded.close();
    }
  });
}
