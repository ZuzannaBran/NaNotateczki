import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:uuid/uuid.dart';

class _FakeGateway implements OperationGateway {
  final List<SequencedOperation> accepted = [];
  final Map<String, int> cursors = {};
  final List<List<String>> batches = [];
  bool dropNextAck = false;

  void seed(OperationEnvelope operation) {
    final cursor = accepted.length + 1;
    cursors[operation.operationId] = cursor;
    accepted.add(SequencedOperation(cursor, operation));
  }

  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    batches.add(operations.map((op) => op.operationId).toList());
    final receipts = <OperationReceipt>[];
    for (final operation in operations) {
      if (!cursors.containsKey(operation.operationId)) {
        seed(operation);
      }
      receipts.add(
        OperationReceipt(
          operation.operationId,
          cursors[operation.operationId]!,
        ),
      );
    }
    if (dropNextAck) {
      dropNextAck = false;
      throw StateError('Server committed, but response was lost.');
    }
    return receipts;
  }

  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    final unread = accepted
        .where((entry) => entry.cursor > cursor)
        .toList();
    return OperationFeedPage(
      cursor: unread.isEmpty ? cursor : unread.last.cursor,
      hasMore: false,
      operations: unread,
    );
  }
}

OperationEnvelope _remote(
  String actor,
  String objectId, {
  String documentId = 'document-one',
}) {
  return OperationEnvelope(
    operationId: const Uuid().v4(),
    actorId: actor,
    actorSeq: 1,
    documentId: documentId,
    pageId: 'page-one',
    objectId: objectId,
    kind: OperationKind.objectCreate,
    payload: {
      'value': {'name': objectId},
    },
    dependencies: const [],
    logicalClock: 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NotesDatabase database;
  late OperationStore store;
  late _FakeGateway gateway;
  late SyncEngine engine;
  late List<List<String>> rebaseObserved;

  setUp(() async {
    database = NotesDatabase(NativeDatabase.memory());
    store = OperationStore(database);
    gateway = _FakeGateway();
    rebaseObserved = [];
    await database.customStatement(
      'CREATE TABLE projection_probe (id TEXT PRIMARY KEY, value TEXT)',
    );
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (remote, pending) async {
        rebaseObserved.add(
          pending.map((operation) => operation.operationId).toList(),
        );
        await database.customStatement(
          'INSERT OR IGNORE INTO projection_probe VALUES (?, ?)',
          [remote.objectId, 'remote'],
        );
      },
    );
  });

  tearDown(() async {
    await engine.stop();
    engine.dispose();
    await database.close();
  });

  Future<OperationEnvelope> local(String id) {
    return engine.writeLocal(
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: id,
      kind: OperationKind.objectCreate,
      payload: {
        'value': {'name': id},
      },
      apply: (_) => database.customStatement(
        'INSERT INTO projection_probe VALUES (?, ?)',
        [id, 'local'],
      ),
    );
  }

  test('invalid create is refused before any SQLite or outbox write', () async {
    await expectLater(
      engine.writeLocal(
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'wrong-payload',
        kind: OperationKind.objectCreate,
        payload: const {
          'properties': {'name': 'wrong-payload'},
        },
        apply: (_) => database.customStatement(
          'INSERT INTO projection_probe VALUES (?, ?)',
          ['wrong-payload', 'must-not-persist'],
        ),
      ),
      throwsFormatException,
    );
    expect(await store.pending(), isEmpty);
    expect(
      await database.customSelect('SELECT * FROM projection_probe').get(),
      isEmpty,
    );
  });

  test('optimistic projection is durable before an HTTP send', () async {
    final operation = await local('local-1');
    final rows = await database.customSelect(
      'SELECT value FROM projection_probe WHERE id = \'local-1\'',
    ).get();
    expect(rows.single.read<String>('value'), 'local');
    expect(await store.isPending(operation.operationId), isTrue);
    expect(gateway.batches, isEmpty);

    await engine.start();
    expect(await store.pending(), isEmpty);
    expect(gateway.batches.single.single, operation.operationId);
  });

  test('lost HTTP ACK is recovered through own feed echo', () async {
    gateway.dropNextAck = true;
    final operation = await local('local-echo');
    await engine.start();
    expect(await store.pending(), isEmpty);
    expect(gateway.accepted, hasLength(1));
    expect(gateway.accepted.single.operation.operationId,
        operation.operationId);
    expect(rebaseObserved, isEmpty);
    final rows = await database.customSelect(
      'SELECT id FROM projection_probe',
    ).get();
    expect(rows, hasLength(1));
    expect(await store.checkpoint('user-A-v2'), 1);
  });

  test('incoming update rebases with all pending local edits', () async {
    final localEdit = await local('local-pending');
    gateway.seed(_remote('actor-remote', 'remote-added'));

    await engine.start();
    expect(rebaseObserved.single, [localEdit.operationId]);
    final rows = await database.customSelect(
      'SELECT id FROM projection_probe ORDER BY id',
    ).get();
    expect(
      rows.map((row) => row.read<String>('id')).toList(),
      ['local-pending', 'remote-added'],
    );
    expect(await store.pending(), isEmpty);
  });

  test('failed projection leaves cursor in place but not other documents',
      () async {
    gateway.seed(_remote('actor-broken', 'bad'));
    gateway.seed(
      _remote('actor-good', 'good', documentId: 'document-other'),
    );
    await engine.stop();
    var fail = true;
    engine.dispose();
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (remote, pending) async {
        if (fail && remote.objectId == 'bad') {
          throw StateError('Projection is temporarily unavailable.');
        }
        await database.customStatement(
          'INSERT INTO projection_probe VALUES (?, ?)',
          [remote.objectId, 'remote'],
        );
      },
    );
    await engine.start();
    expect(await store.checkpoint('user-A-v2'), 0);
    expect(await store.operation(gateway.accepted.last.operation.operationId),
        isNotNull);

    fail = false;
    await engine.syncNow();
    expect(await store.checkpoint('user-A-v2'), 2);
    final rows = await database.customSelect(
      'SELECT id FROM projection_probe',
    ).get();
    expect(rows, hasLength(2));
  });

  test('independent documents use distinct actor sequences', () async {
    final first = await local('first-document');
    final second = await engine.writeLocal(
      documentId: 'document-two',
      pageId: 'page-two',
      objectId: 'second-document',
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {'name': 'second-document'},
      },
      apply: (_) => database.customStatement(
        'INSERT INTO projection_probe VALUES (?, ?)',
        ['second-document', 'local'],
      ),
    );
    expect(first.actorSeq, 1);
    expect(second.actorSeq, 1);
    expect(first.actorId, isNot(second.actorId));
    expect(second.dependencies, isNot(contains(first.operationId)));
  });

  test('deferred predecessor blocks a later actor sequence', () async {
    final first = await local('first');
    final second = await local('second');
    await store.scheduleRetry(
      first.operationId,
      delay: const Duration(minutes: 1),
    );
    expect(await store.pending(), isEmpty);
    expect(
      (await store.pending(includeDeferred: true))
          .map((operation) => operation.operationId),
      [first.operationId, second.operationId],
    );
  });

  test('a retry preserves the original operation identity', () async {
    final first = await local('retry');
    gateway.dropNextAck = true;
    await engine.start();
    // The server has accepted the operation; the lost response is repaired
    // from the feed without generating a second operation or projection.
    expect(gateway.cursors, hasLength(1));
    expect(gateway.cursors.keys.single, first.operationId);
    expect((await store.operation(first.operationId))?.actorSeq, 1);
  });
}
