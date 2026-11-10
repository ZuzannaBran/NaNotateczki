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

  test('batch ACK is all-or-nothing on an unknown operation', () async {
    final first = await add('batch-ack-first');
    final second = await add('batch-ack-second');
    await expectLater(
      store.acknowledgeBatch({first.operationId: 51, const Uuid().v4(): 52}),
      throwsStateError,
    );
    expect((await store.pending()).map((op) => op.operationId), [
      first.operationId,
      second.operationId,
    ]);
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      isEmpty,
    );
    await store.acknowledgeBatch({
      first.operationId: 51,
      second.operationId: 52,
    });
    expect(await store.pending(), isEmpty);
    await store.acknowledgeBatch({
      first.operationId: 51,
      second.operationId: 52,
    });
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      hasLength(2),
    );
  });

  test('batch ACK conflict keeps unacknowledged entries', () async {
    final first = await add('batch-acked-first');
    final second = await add('batch-pending-second');
    final third = await add('batch-pending-third');
    await store.acknowledge(first.operationId, serverSequence: 61);
    await expectLater(
      store.acknowledgeBatch({second.operationId: 62, first.operationId: 999}),
      throwsStateError,
    );
    expect(await store.isPending(second.operationId), isTrue);
    expect(await store.isPending(third.operationId), isTrue);
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      hasLength(1),
    );
    await store.acknowledgeBatch({
      first.operationId: 61,
      second.operationId: 62,
      third.operationId: 63,
    });
    expect(await store.pending(), isEmpty);
  });

  test('duplicate cursor ACK cannot remove either outbox entry', () async {
    final first = await add('duplicate-first');
    final second = await add('duplicate-second');
    await expectLater(
      store.acknowledgeBatch({first.operationId: 71, second.operationId: 71}),
      throwsArgumentError,
    );
    expect(await store.pending(), hasLength(2));
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      isEmpty,
    );
  });

  test('stored batch rejects reversed actor cursors', () async {
    final first = await add('actor-sequence-first');
    final second = await add('actor-sequence-second');
    await expectLater(
      store.acknowledgeBatch({first.operationId: 95, second.operationId: 94}),
      throwsStateError,
    );
    expect(await store.pending(), hasLength(2));
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      isEmpty,
    );
    await store.acknowledgeBatch({
      second.operationId: 96,
      first.operationId: 95,
    });
    expect(await store.pending(), isEmpty);
  });

  test('unsafe cursor cannot ACK, checkpoint or snapshot', () async {
    final operation = await add('unsafe-cursor');
    final invalid = OperationEnvelope.maxSafeInteger + 1;
    await expectLater(
      store.acknowledgeBatch({operation.operationId: invalid}),
      throwsArgumentError,
    );
    await expectLater(
      store.advanceCheckpoint('test-unsafe-cursor', invalid),
      throwsArgumentError,
    );
    await expectLater(
      store.saveSnapshot(
        documentId: 'document-one',
        serverSequence: invalid,
        snapshotJson: '{}',
      ),
      throwsArgumentError,
    );
    expect(await store.isPending(operation.operationId), isTrue);
    expect(await store.checkpoint('test-unsafe-cursor'), 0);
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      isEmpty,
    );
  });

  test('remote-only operation cannot be acknowledged as local', () async {
    final remote = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'remote-actor',
      actorSeq: 1,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'remote-object',
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {'label': 'remote'},
      },
      dependencies: const [],
      logicalClock: 1,
    );
    await store.applyRemote(remote, serverSequence: 1, apply: () async {});
    final local = await add('real-local');
    await expectLater(
      store.acknowledgeBatch({local.operationId: 81, remote.operationId: 82}),
      throwsStateError,
    );
    expect(await store.isPending(local.operationId), isTrue);
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      isEmpty,
    );
  });

  test('failed file-backed batch ACK survives restart intact', () async {
    final directory = await Directory.systemTemp.createTemp('nn-v2-ack-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/notes.sqlite');
    final original = NotesDatabase(NativeDatabase(file));
    late String firstId;
    late String secondId;
    try {
      final journal = OperationStore(original);
      final first = await journal.writeLocal(
        actorId: 'restart-ack-actor',
        documentId: 'restart-ack-document',
        pageId: 'page',
        objectId: 'first',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'label': 'first'},
        },
        apply: (_) async {},
      );
      final second = await journal.writeLocal(
        actorId: 'restart-ack-actor',
        documentId: 'restart-ack-document',
        pageId: 'page',
        objectId: 'second',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'label': 'second'},
        },
        apply: (_) async {},
      );
      firstId = first.operationId;
      secondId = second.operationId;
      await original.customStatement(
        'CREATE TRIGGER interrupt_second_ack '
        'BEFORE INSERT ON operation_ack '
        "WHEN NEW.operation_id = '${second.operationId}' "
        "BEGIN SELECT RAISE(ABORT, 'injected rollback'); END",
      );
      await expectLater(
        journal.acknowledgeBatch({firstId: 101, secondId: 102}),
        throwsException,
      );
    } finally {
      await original.close();
    }
    final restarted = NotesDatabase(NativeDatabase(file));
    try {
      final journal = OperationStore(restarted);
      expect((await journal.pending()).map((op) => op.operationId), [
        firstId,
        secondId,
      ]);
      expect(
        (await restarted.customSelect('SELECT * FROM operation_ack').get()),
        isEmpty,
      );
      await restarted.customStatement('DROP TRIGGER interrupt_second_ack');
      await journal.acknowledgeBatch({firstId: 101, secondId: 102});
      expect(await journal.pending(), isEmpty);
      expect(
        (await restarted.customSelect('SELECT * FROM operation_ack').get()),
        hasLength(2),
      );
    } finally {
      await restarted.close();
    }
  });

  test('old server cursor cannot ACK a different local operation', () async {
    final first = await add('cursor-bound-first');
    final second = await add('cursor-bound-second');
    await store.acknowledge(first.operationId, serverSequence: 301);
    await expectLater(
      store.acknowledge(second.operationId, serverSequence: 301),
      throwsStateError,
    );
    expect(await store.isPending(second.operationId), isTrue);
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      hasLength(1),
    );
    await store.acknowledge(second.operationId, serverSequence: 302);
    expect(await store.pending(), isEmpty);
  });

  test('old ACK cannot reverse actor order across separate batches', () async {
    final first = await add('historical-order-first');
    final second = await add('historical-order-second');
    await store.acknowledge(first.operationId, serverSequence: 500);
    await expectLater(
      store.acknowledge(second.operationId, serverSequence: 499),
      throwsStateError,
    );
    expect(await store.isPending(second.operationId), isTrue);
    await store.acknowledge(second.operationId, serverSequence: 501);
    expect(await store.pending(), isEmpty);
  });

  test('late ACK for earlier actor sequence cannot overtake later', () async {
    final first = await add('late-ack-first');
    final second = await add('late-ack-second');
    await store.acknowledge(second.operationId, serverSequence: 601);
    await expectLater(
      store.acknowledge(first.operationId, serverSequence: 602),
      throwsStateError,
    );
    expect(await store.isPending(first.operationId), isTrue);
    await store.acknowledge(first.operationId, serverSequence: 600);
    expect(await store.pending(), isEmpty);
  });

  test('previously used cursor is rejected across distinct actors', () async {
    final first = await add('cross-actor-first');
    final second = await add('cross-actor-second', actorId: 'other-device');
    await store.acknowledge(first.operationId, serverSequence: 701);
    await expectLater(
      store.acknowledge(second.operationId, serverSequence: 701),
      throwsStateError,
    );
    expect(await store.isPending(second.operationId), isTrue);
    await store.acknowledge(second.operationId, serverSequence: 702);
    expect(await store.pending(), isEmpty);
  });

  test('cursor binding survives SQLite restart across ACK batches', () async {
    final directory = await Directory.systemTemp.createTemp('ack-binding-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/notes.sqlite');
    late String firstId;
    late String secondId;
    final firstDatabase = NotesDatabase(NativeDatabase(file));
    try {
      final journal = OperationStore(firstDatabase);
      final first = await journal.writeLocal(
        actorId: 'cursor-restart-actor',
        documentId: 'cursor-restart-note',
        pageId: 'page',
        objectId: 'one',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'name': 'one'},
        },
        apply: (_) async {},
      );
      final second = await journal.writeLocal(
        actorId: 'cursor-restart-actor',
        documentId: 'cursor-restart-note',
        pageId: 'page',
        objectId: 'two',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'name': 'two'},
        },
        apply: (_) async {},
      );
      firstId = first.operationId;
      secondId = second.operationId;
      await journal.acknowledge(firstId, serverSequence: 801);
    } finally {
      await firstDatabase.close();
    }
    final recovered = NotesDatabase(NativeDatabase(file));
    try {
      final journal = OperationStore(recovered);
      expect(await journal.isPending(secondId), isTrue);
      await expectLater(
        journal.acknowledge(secondId, serverSequence: 801),
        throwsStateError,
      );
      await expectLater(
        journal.acknowledge(secondId, serverSequence: 799),
        throwsStateError,
      );
      expect(await journal.isPending(secondId), isTrue);
      await journal.acknowledge(secondId, serverSequence: 802);
      expect(await journal.pending(), isEmpty);
    } finally {
      await recovered.close();
    }
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
    expect(upgraded.schemaVersion, 8);
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
      expect(upgraded.schemaVersion, 8);
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
        'operation_asset_bytes',
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
      expect(upgraded.schemaVersion, 8);
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

  test('compact cursor covers 300 committed remote actor heads', () async {
    store = OperationStore(database, checkpointScope: 'account:test');
    for (var i = 0; i < 300; i++) {
      final id =
          '${(i + 4000).toRadixString(16).padLeft(8, '0')}'
          '-1111-4111-8111-111111111111';
      final remote = OperationEnvelope(
        operationId: id,
        actorId: 'peer-$i',
        actorSeq: 1,
        logicalClock: i + 1,
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'peer-$i',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'x': 1},
        },
        dependencies: const [],
      );
      await store.applyRemote(
        remote,
        serverSequence: i + 1,
        checkpointScope: 'account:test',
        apply: () async {},
      );
    }
    final local = await add('compact-after-300');
    expect(local.dependencies, isEmpty);
    expect(local.causalCursor, 300);
    expect(local.logicalClock, 301);
    const laterId = '00002000-1111-4111-8111-111111111111';
    await store.applyRemote(
      OperationEnvelope(
        operationId: laterId,
        actorId: 'late-peer',
        actorSeq: 1,
        logicalClock: 305,
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'late-peer',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'x': 2},
        },
        dependencies: const [],
      ),
      serverSequence: 302,
      apply: () async {},
    );
    final next = await add('after-uncheckpointed-peer');
    expect(next.causalCursor, 300);
    expect(next.dependencies, contains(laterId));
    expect(next.logicalClock, 306);
  });

  test('remote receipts are scoped to the account feed', () async {
    store = OperationStore(database, checkpointScope: 'account:test');
    final remote = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'peer',
      actorSeq: 1,
      logicalClock: 1,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'remote-peer',
      kind: OperationKind.objectCreate,
      payload: const {
          'value': {'x': 1},
        },
      dependencies: const [],
    );
    await store.applyRemote(remote, serverSequence: 42, apply: () async {});
    expect(await store.checkpoint('remote-actor:["account:test","peer"]'), 42);
    expect(await store.checkpoint('remote-actor:peer'), 0);
    final local = await add('after-scoped-remote');
    expect(local.dependencies, contains(remote.operationId));
    expect(local.causalCursor, isNull);
  });

  test('compact remote cannot cover its own or future cursor', () async {
    final remote = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'future-peer',
      actorSeq: 1,
      logicalClock: 3,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'future-object',
      kind: OperationKind.objectCreate,
      payload: const {
          'value': {'x': 1},
        },
      dependencies: const [],
      causalCursor: 3,
    );
    await expectLater(
      store.applyRemote(
        remote,
        serverSequence: 3,
        coveredCursor: 3,
        apply: () async {},
      ),
      throwsStateError,
    );
    expect(await store.operation(remote.operationId), isNull);
    expect(await store.pending(), isEmpty);
  });

  test('compact predecessor requires persisted receipt', () async {
    store = OperationStore(database, checkpointScope: 'account:test');
    final first = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'same-remote',
      actorSeq: 1,
      logicalClock: 1,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'first-remote',
      kind: OperationKind.objectCreate,
      payload: const {
          'value': {'x': 1},
        },
      dependencies: const [],
    );
    await store.applyRemote(
      first,
      serverSequence: 50,
      checkpointScope: 'account:test',
      apply: () async {},
    );
    final second = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: first.actorId,
      actorSeq: 2,
      logicalClock: 2,
      documentId: first.documentId,
      pageId: first.pageId,
      objectId: 'second-remote',
      kind: OperationKind.objectCreate,
      payload: const {
          'value': {'x': 2},
        },
      dependencies: const [],
      causalCursor: 50,
    );
    const actorScope = 'remote-actor:["account:test","same-remote"]';
    await database.customStatement(
      'DELETE FROM sync_checkpoints WHERE scope = ?',
      [actorScope],
    );
    await expectLater(
      store.applyRemote(
        second,
        serverSequence: 51,
        coveredCursor: 50,
        apply: () async {},
      ),
      throwsStateError,
    );
    expect(await store.operation(second.operationId), isNull);
    await store.advanceCheckpoint(actorScope, 50);
    expect(
      await store.applyRemote(
        second,
        serverSequence: 51,
        coveredCursor: 50,
        apply: () async {},
      ),
      isTrue,
    );
    expect(await store.operation(second.operationId), isNotNull);
  });

  test('compact remote cannot bypass an unresolved feed gap', () async {
    store = OperationStore(database, checkpointScope: 'account:test');
    final remote = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'compact-peer',
      actorSeq: 1,
      logicalClock: 3,
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'compact-remote',
      kind: OperationKind.objectCreate,
      payload: const {
          'value': {'x': 1},
        },
      dependencies: const [],
      causalCursor: 2,
    );
    await expectLater(
      store.applyRemote(
        remote,
        serverSequence: 3,
        coveredCursor: 1,
        apply: () async {},
      ),
      throwsStateError,
    );
    expect(await store.operation(remote.operationId), isNull);
    expect(await store.checkpoint('remote-actor:compact-peer'), 0);
  });

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
