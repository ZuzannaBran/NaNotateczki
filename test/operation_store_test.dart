import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
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
        'value': {'label': objectId},
      },
      apply: (_) => database.customStatement(
        'INSERT INTO projection_probe (id, value) VALUES (?, ?)',
        [objectId, objectId],
      ),
    );
  }

  test('direct store writes reject malformed create payloads', () async {
    await expectLater(
      store.writeLocal(
        actorId: 'device-one',
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'invalid',
        kind: OperationKind.objectCreate,
        payload: const {
          'properties': {'label': 'invalid'},
        },
        apply: (_) async {
          throw StateError('Projection must not be invoked.');
        },
      ),
      throwsFormatException,
    );
    expect(await store.pending(), isEmpty);
    expect(await store.operation(const Uuid().v4()), isNull);
  });

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

  test('a multi-object gesture commits one actor chain', () async {
    final committed = await store.writeLocalBatch(
      actorId: 'device-one',
      documentId: 'document-one',
      operations: [
        for (final id in ['stroke-one', 'text-one', 'image-one'])
          LocalOperationDraft(
            pageId: 'page-one',
            objectId: id,
            kind: OperationKind.objectCreate,
            payload: {
              'value': {'label': id},
            },
          ),
      ],
      apply: (operation) => database.customStatement(
        'INSERT INTO projection_probe (id, value) VALUES (?, ?)',
        [operation.objectId!, operation.objectId!],
      ),
    );
    expect(committed.map((op) => op.actorSeq).toList(), [1, 2, 3]);
    expect(committed[1].dependencies, contains(committed[0].operationId));
    expect(committed[2].dependencies, contains(committed[1].operationId));
    expect(
      (await store.pending()).map((op) => op.operationId).toList(),
      committed.map((op) => op.operationId).toList(),
    );
    expect(
      (await database.customSelect('SELECT * FROM projection_probe').get())
          .length,
      3,
    );
  });

  test('failed gesture rolls back all projections and outbox items', () async {
    await expectLater(
      store.writeLocalBatch(
        actorId: 'device-one',
        documentId: 'document-one',
        operations: [
          for (final id in ['before-failure', 'fail', 'after-failure'])
            LocalOperationDraft(
              pageId: 'page-one',
              objectId: id,
              kind: OperationKind.objectCreate,
              payload: {
                'value': {'label': id},
              },
            ),
        ],
        apply: (operation) async {
          if (operation.objectId == 'fail') {
            throw StateError('Projection failed mid-gesture.');
          }
          await database.customStatement(
            'INSERT INTO projection_probe (id, value) VALUES (?, ?)',
            [operation.objectId!, operation.objectId!],
          );
        },
      ),
      throwsStateError,
    );
    expect(await store.pending(), isEmpty);
    expect(
      await database.customSelect('SELECT * FROM projection_probe').get(),
      isEmpty,
    );
    expect((await add('retry-after-failure')).actorSeq, 1);
  });

  test(
    'single write does not interleave into a multi-object gesture',
    () async {
      final tasks = await Future.wait([
        store
            .writeLocalBatch(
              actorId: 'device-one',
              documentId: 'document-one',
              operations: [
                for (final id in ['first', 'second'])
                  LocalOperationDraft(
                    pageId: 'page-one',
                    objectId: id,
                    kind: OperationKind.objectCreate,
                    payload: {
                      'value': {'label': id},
                    },
                  ),
              ],
              apply: (operation) => database.customStatement(
                'INSERT INTO projection_probe VALUES (?, ?)',
                [operation.objectId!, operation.objectId!],
              ),
            )
            .then((ops) => ops.map((op) => op.actorSeq).toList()),
        add('third').then((op) => [op.actorSeq]),
      ]);
      expect(tasks, [
        [1, 2],
        [3],
      ]);
      expect(await store.pending(), hasLength(3));
    },
  );

  test('failed projection rolls back actor counter and outbox', () async {
    await expectLater(
      store.writeLocal(
        actorId: 'device-one',
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'lost-object',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'label': 'valid data before disk failure'},
        },
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
    final rows = await database
        .customSelect('SELECT * FROM projection_probe')
        .get();
    expect(rows, isEmpty);
    expect((await add('safe-object')).actorSeq, 1);
  });

  test(
    'local intent depends on every committed remote actor frontier',
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
    },
  );

  test('undo automatically depends on the reverted operation', () async {
    final created = await add('undo-object');
    final undo = await store.writeLocal(
      actorId: 'device-one',
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'undo-object',
      kind: OperationKind.objectDelete,
      payload: const {},
      revertsOperationId: created.operationId,
      apply: (_) => database.customStatement(
        'DELETE FROM projection_probe WHERE id = ?',
        ['undo-object'],
      ),
    );
    expect(undo.dependencies, contains(created.operationId));
  });

  test(
    'unrelated remote actor frontiers never leak into dependencies',
    () async {
      final remote = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'unrelated-actor',
        actorSeq: 1,
        documentId: 'another-document',
        pageId: 'other-page',
        objectId: 'other-object',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'name': 'remote'},
        },
        dependencies: const [],
        logicalClock: 4,
      );
      await store.applyRemote(remote, serverSequence: 1, apply: () async {});
      final local = await add('local-in-this-document');
      expect(local.dependencies, isNot(contains(remote.operationId)));
    },
  );

  test(
    'stale remote edit after tombstone is logged but not projected',
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
      final rows = await database
          .customSelect(
            'SELECT * FROM projection_probe WHERE id = ?',
            variables: [Variable<String>('deleted-earlier')],
          )
          .get();
      expect(rows, isEmpty);
    },
  );

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
        pageId: 'page-one',
      ),
      isTrue,
    );
    await expectLater(add('deleted-object'), throwsStateError);
    expect((await add('new-identity')).actorSeq, 3);
  });

  test(
    'a tombstone on page one does not delete the same ID on page two',
    () async {
      final first = await add('same-id');
      final deleted = await store.writeLocal(
        actorId: 'device-one',
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'same-id',
        kind: OperationKind.objectDelete,
        payload: const {},
        apply: (_) async {},
      );
      expect(
        await store.isTombstoned(
          'document-one',
          'object',
          'same-id',
          pageId: 'page-one',
        ),
        isTrue,
      );
      expect(
        await store.isTombstoned(
          'document-one',
          'object',
          'same-id',
          pageId: 'page-two',
        ),
        isFalse,
      );
      final anotherPage = await store.writeLocal(
        actorId: 'device-one',
        documentId: 'document-one',
        pageId: 'page-two',
        objectId: 'same-id',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'name': 'on another page'},
        },
        apply: (_) async {},
      );
      expect(anotherPage.dependencies, contains(deleted.operationId));
      expect(anotherPage.dependencies, isNot(contains(first.operationId)));
    },
  );

  test('permanent failure survives and blocks only its own actor', () async {
    final first = await add('blocked');
    final next = await add('same-actor-after-blocked');
    final other = await add('other-actor', actorId: 'device-two');
    await store.markBlocked(first.operationId, 'Server rejected 422');
    expect(await store.blockedReason(first.operationId), 'Server rejected 422');
    expect((await store.pending()).map((op) => op.operationId), [
      other.operationId,
    ]);
    expect(
      (await store.pending(includeDeferred: true)).map((op) => op.operationId),
      [first.operationId, next.operationId, other.operationId],
    );
    expect(await store.isPending(first.operationId), isTrue);
  });

  test(
    'outbox pagination returns every pending intent in actor order',
    () async {
      for (var i = 0; i < 5; i++) {
        await add('paginated-$i');
      }
      expect(
        (await store.pending(
          limit: 2,
        )).map((operation) => operation.actorSeq).toList(),
        [1, 2],
      );
      expect(
        (await store.pending(
          limit: 2,
          offset: 2,
        )).map((operation) => operation.actorSeq).toList(),
        [3, 4],
      );
      expect(
        (await store.pending(
          limit: 2,
          offset: 4,
        )).map((operation) => operation.actorSeq).toList(),
        [5],
      );
    },
  );

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
    expect((await store.latestSnapshot('document-one'))?.sha256, saved.sha256);
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
    expect(
      written.map((operation) => operation.actorSeq),
      List<int>.generate(20, (index) => index + 1),
    );
    expect(await store.pending(), hasLength(20));
  });

  test('v4 upgrade retains queued outbox and persists blocked state', () async {
    final directory = await Directory.systemTemp.createTemp('notes-v4-v5-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/notes.sqlite');
    final initial = NotesDatabase(NativeDatabase(file));
    final original = await OperationStore(initial).writeLocal(
      actorId: 'migration-actor',
      documentId: 'migration-document',
      pageId: 'page',
      objectId: 'object',
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {'name': 'survive'},
      },
      apply: (_) async {},
    );
    await initial.close();

    final raw = sqlite.sqlite3.open(file.path);
    try {
      raw.execute(
        'ALTER TABLE operation_outbox '
        'RENAME TO operation_outbox_v5',
      );
      raw.execute(
        'CREATE TABLE operation_outbox ('
        'operation_id TEXT NOT NULL PRIMARY KEY '
        'REFERENCES operations(operation_id) ON DELETE RESTRICT, '
        'queued_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, '
        'retry_after INTEGER NOT NULL DEFAULT 0)',
      );
      raw.execute(
        'INSERT INTO operation_outbox '
        '(operation_id, queued_at, attempts, retry_after) '
        'SELECT operation_id, queued_at, attempts, retry_after '
        'FROM operation_outbox_v5',
      );
      raw.execute('DROP TABLE operation_outbox_v5');
      raw.execute('PRAGMA user_version = 4');
    } finally {
      raw.dispose();
    }

    final upgraded = NotesDatabase(NativeDatabase(file));
    final upgradedStore = OperationStore(upgraded);
    expect(upgraded.schemaVersion, 6);
    expect(
      (await upgradedStore.pending()).single.operationId,
      original.operationId,
    );
    await upgradedStore.markBlocked(original.operationId, 'Permanent 422');
    await upgraded.close();

    final reopened = NotesDatabase(NativeDatabase(file));
    try {
      final restored = OperationStore(reopened);
      expect(
        await restored.blockedReason(original.operationId),
        'Permanent 422',
      );
      expect(await restored.pending(), isEmpty);
      expect(
        (await restored.pending(includeDeferred: true)).single.operationId,
        original.operationId,
      );
    } finally {
      await reopened.close();
    }
  });

  test('v3 upgrades tombstones without losing the deleted page ID', () async {
    final directory = await Directory.systemTemp.createTemp('notes-v3-v4-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/notes.sqlite');
    final initial = NotesDatabase(NativeDatabase(file));
    final initialStore = OperationStore(initial);
    await initialStore.writeLocal(
      actorId: 'legacy-actor',
      documentId: 'legacy-document',
      pageId: 'original-page',
      objectId: 'old-object',
      kind: OperationKind.objectDelete,
      payload: const {},
      apply: (_) async {},
    );
    await initial.close();

    final raw = sqlite.sqlite3.open(file.path);
    try {
      raw.execute('DROP TABLE object_tombstones');
      raw.execute(
        'CREATE TABLE object_tombstones ('
        'document_id TEXT NOT NULL, target_kind TEXT NOT NULL, '
        'object_id TEXT NOT NULL, operation_id TEXT NOT NULL, '
        'PRIMARY KEY(document_id, target_kind, object_id))',
      );
      raw.execute(
        "INSERT INTO object_tombstones "
        "(document_id, target_kind, object_id, operation_id) "
        "SELECT document_id, 'object', object_id, operation_id "
        "FROM operations WHERE kind = 'object.delete'",
      );
      raw.execute('PRAGMA user_version = 3');
    } finally {
      raw.dispose();
    }

    final upgraded = NotesDatabase(NativeDatabase(file));
    try {
      final updatedStore = OperationStore(upgraded);
      expect(
        await updatedStore.isTombstoned(
          'legacy-document',
          'object',
          'old-object',
          pageId: 'original-page',
        ),
        isTrue,
      );
      expect(
        await updatedStore.isTombstoned(
          'legacy-document',
          'object',
          'old-object',
          pageId: 'other-page',
        ),
        isFalse,
      );
      expect(upgraded.schemaVersion, 6);
    } finally {
      await upgraded.close();
    }
  });

  test('v2 upgrades to v4 preserving legacy notebooks', () async {
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
      final legacy = await upgraded
          .customSelect(
            'SELECT title FROM notebook_rows WHERE uid = ?',
            variables: [const Variable<String>('preserved')],
          )
          .getSingle();
      expect(legacy.read<String>('title'), 'Legacy notebook');
      final operations = await upgraded
          .customSelect(
            'SELECT name FROM sqlite_master '
            "WHERE type = 'table' AND name = 'operations'",
          )
          .getSingle();
      expect(operations.read<String>('name'), 'operations');
      expect(upgraded.schemaVersion, 6);
    } finally {
      await upgraded.close();
    }
  });

  test(
    'cross-document causal dependencies roll back without an outbox',
    () async {
      final foreign = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'remote-foreign',
        actorSeq: 1,
        documentId: 'foreign-document',
        kind: OperationKind.documentCreate,
        payload: const {
          'value': {'title': 'Other'},
        },
        dependencies: const [],
        logicalClock: 1,
      );
      await store.applyRemote(foreign, serverSequence: 1, apply: () async {});
      await expectLater(
        store.writeLocal(
          actorId: 'local-document',
          documentId: 'document-one',
          pageId: 'page-one',
          objectId: 'isolated',
          kind: OperationKind.objectCreate,
          payload: const {
            'value': {'label': 'isolated'},
          },
          dependencies: [foreign.operationId],
          apply: (_) async {
            await database.customStatement(
              'INSERT INTO projection_probe VALUES (?, ?)',
              ['isolated', 'wrong'],
            );
          },
        ),
        throwsStateError,
      );
      expect(await store.pending(), isEmpty);
      expect(
        await database.customSelect('SELECT * FROM projection_probe').get(),
        isEmpty,
      );
    },
  );

  test('snapshot cannot predate an ACK or a later snapshot', () async {
    final operation = await add('ack-before-snapshot');
    await store.acknowledge(operation.operationId, serverSequence: 7);
    await expectLater(
      store.saveSnapshot(
        documentId: 'document-one',
        serverSequence: 6,
        snapshotJson: '{"objects":0}',
      ),
      throwsStateError,
    );
    await store.saveSnapshot(
      documentId: 'document-one',
      serverSequence: 10,
      snapshotJson: '{"objects":1}',
    );
    await expectLater(
      store.saveSnapshot(
        documentId: 'document-one',
        serverSequence: 9,
        snapshotJson: '{"objects":0}',
      ),
      throwsStateError,
    );
    expect((await store.latestSnapshot('document-one'))?.serverSequence, 10);
  });

  test(
    'asset references preserve same object ID across different pages',
    () async {
      for (final page in ['first-page', 'second-page']) {
        await store.attachAssetReference(
          documentId: 'document-one',
          pageId: page,
          objectId: 'shared-object',
          assetId: 'asset-one',
          storagePath: 'images/asset-one',
          checksumSha256: List.filled(64, 'a').join(),
          byteLength: 5,
        );
      }
      final rows = await database
          .customSelect(
            'SELECT object_id FROM asset_references ORDER BY object_id',
          )
          .get();
      expect(rows, hasLength(2));
      expect(
        rows.map((row) => row.read<String>('object_id')),
        containsAll([
          'page:["first-page","shared-object"]',
          'page:["second-page","shared-object"]',
        ]),
      );
    },
  );

  test(
    'local journal prunes implied frontiers but keeps causal order',
    () async {
      String? parent;
      for (var i = 0; i < 260; i++) {
        final id =
            '${(i + 1000).toRadixString(16).padLeft(8, '0')}'
            '-1111-4111-8111-111111111111';
        final remote = OperationEnvelope(
          operationId: id,
          actorId: 'remote-$i',
          actorSeq: 1,
          logicalClock: i + 1,
          documentId: 'document-one',
          pageId: 'page-one',
          objectId: 'remote-$i',
          kind: OperationKind.objectCreate,
          payload: const {
            'value': {'x': 1},
          },
          dependencies: [if (parent != null) parent],
        );
        await store.applyRemote(
          remote,
          serverSequence: i + 1,
          apply: () async {},
        );
        parent = id;
      }
      final next = await add('local-after-frontier');
      expect(next.dependencies, [parent]);
      expect(next.logicalClock, 261);
    },
  );
}
