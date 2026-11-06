import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
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
    final unread = accepted.where((entry) => entry.cursor > cursor).toList();
    return OperationFeedPage(
      cursor: unread.isEmpty ? cursor : unread.last.cursor,
      hasMore: false,
      operations: unread,
    );
  }
}

class _PoisonBatchGateway extends _FakeGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    if (operations.any((operation) => operation.objectId == 'bad')) {
      throw const ApiException(422, 'Bad object projection');
    }
    return super.send(operations);
  }
}

class _RetryGateway extends _FakeGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    if (operations.first.documentId == 'document-one') {
      throw const ApiException(422, 'Invalid payload');
    }
    throw StateError('Temporary network failure');
  }
}

class _RevokedShareGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw const ApiException(410, 'Shared session expired.');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw const ApiException(410, 'Shared session expired.');
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

  test(
    'stopping during asset preparation cannot send old account edits',
    () async {
      final operation = await local('uploading-object');
      engine.dispose();
      final preparing = Completer<void>();
      final release = Completer<void>();
      engine = SyncEngine(
        store: store,
        gateway: gateway,
        actorId: 'actor-local',
        checkpointScope: 'user-A-v2',
        enableRealtime: false,
        applyRemote: (_, __) async {},
        prepareLocalOperations: (_) async {
          preparing.complete();
          await release.future;
        },
      );
      final starting = engine.start();
      await preparing.future;
      final stopping = engine.stop();
      release.complete();
      await starting;
      await stopping;
      expect(gateway.batches, isEmpty);
      expect(await store.isPending(operation.operationId), isTrue);
    },
  );

  test(
    'WebSocket authentication catches up missed events after restart',
    () async {
      await engine.stop();
      engine.dispose();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final authenticated = StreamController<WebSocket>();
      final connections = StreamIterator(authenticated.stream);
      final sockets = <WebSocket>[];
      final api = ApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      )..setAccessToken('realtime-test-token');
      final delivered = <String, Completer<void>>{};
      server.listen((request) async {
        expect(request.uri.path, '/v2/realtime');
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((event) {
          final message = jsonDecode(event as String) as Map;
          expect(message['type'], 'authenticate');
          expect(message['token'], 'realtime-test-token');
          authenticated.add(socket);
        });
      });
      engine = SyncEngine(
        store: store,
        gateway: gateway,
        actorId: 'realtime-client',
        checkpointScope: 'realtime-catch-up',
        apiClient: api,
        pollInterval: const Duration(days: 1),
        applyRemote: (operation, _) async {
          await database.customStatement(
            'INSERT OR IGNORE INTO projection_probe VALUES (?, ?)',
            [operation.objectId, 'remote'],
          );
          delivered[operation.objectId]!.complete();
        },
      );
      addTearDown(() async {
        await engine.stop();
        await connections.cancel();
        await authenticated.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        api.close();
      });
      for (var cycle = 0; cycle < 2; cycle++) {
        final started = engine.start();
        expect(
          await connections.moveNext().timeout(const Duration(seconds: 3)),
          isTrue,
        );
        await started;
        final remote = _remote('missed-$cycle', 'missed-$cycle');
        final applied = Completer<void>();
        delivered[remote.objectId!] = applied;
        gateway.seed(remote);
        // The subscription missed the commit. No operations_changed hint,
        // manual sync or periodic poll may rescue this missing operation.
        final previousSync = engine.lastSuccessfulSync;
        final synced = Completer<void>();
        void onSynced() {
          if (!synced.isCompleted &&
              engine.lastSuccessfulSync != previousSync) {
            synced.complete();
          }
        }

        engine.addListener(onSynced);
        try {
          connections.current.add(jsonEncode({'type': 'authenticated'}));
          await applied.future.timeout(const Duration(seconds: 3));
          await synced.future.timeout(const Duration(seconds: 3));
        } finally {
          engine.removeListener(onSynced);
        }
        await engine.stop();
        expect(await store.operation(remote.operationId), isNotNull);
        expect(await store.checkpoint('realtime-catch-up'), cycle + 1);
      }
    },
  );

  test('batch API commits and ACKs a completed gesture once', () async {
    final drafts = [
      for (final id in ['ink-a', 'ink-b', 'ink-c'])
        LocalOperationDraft(
          kind: OperationKind.objectCreate,
          pageId: 'page-one',
          objectId: id,
          payload: {
            'value': {'label': id},
          },
        ),
    ];
    final committed = await engine.writeLocalBatch(
      documentId: 'document-one',
      operations: drafts,
      apply: (operation) => database.customStatement(
        'INSERT INTO projection_probe VALUES (?, ?)',
        [operation.objectId!, 'local'],
      ),
    );
    expect(committed.map((op) => op.actorSeq), [1, 2, 3]);
    expect(committed[1].dependencies, contains(committed.first.operationId));
    expect((await store.pending()).length, 3);
    expect(
      (await database.customSelect('SELECT * FROM projection_probe').get())
          .length,
      3,
    );

    await engine.start();
    expect(await store.pending(), isEmpty);
    expect(gateway.accepted, hasLength(3));
    expect(rebaseObserved, isEmpty);
    expect(
      (await database.customSelect('SELECT * FROM projection_probe').get())
          .length,
      3,
    );
  });

  test('batch API rolls back all writes and actor sequence on error', () async {
    await expectLater(
      engine.writeLocalBatch(
        documentId: 'document-one',
        operations: [
          for (final id in ['good', 'failed', 'never'])
            LocalOperationDraft(
              kind: OperationKind.objectCreate,
              pageId: 'page-one',
              objectId: id,
              payload: {
                'value': {'label': id},
              },
            ),
        ],
        apply: (operation) async {
          if (operation.objectId == 'failed') {
            throw StateError('Projection failed.');
          }
          await database.customStatement(
            'INSERT INTO projection_probe VALUES (?, ?)',
            [operation.objectId!, 'temporary'],
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
    expect((await local('recovered')).actorSeq, 1);
  });

  test(
    'batch prevalidates every draft before writing the projection',
    () async {
      var touched = false;
      await expectLater(
        engine.writeLocalBatch(
          documentId: 'document-one',
          operations: const [
            LocalOperationDraft(
              kind: OperationKind.objectCreate,
              pageId: 'page-one',
              objectId: 'valid',
              payload: {
                'value': {'label': 'valid'},
              },
            ),
            LocalOperationDraft(
              kind: OperationKind.objectCreate,
              pageId: 'page-one',
              objectId: 'invalid',
              payload: {
                'properties': {'label': 'invalid'},
              },
            ),
          ],
          apply: (_) async {
            touched = true;
          },
        ),
        throwsFormatException,
      );
      expect(touched, isFalse);
      expect(await store.pending(), isEmpty);
    },
  );

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
    final rows = await database
        .customSelect(
          'SELECT value FROM projection_probe WHERE id = \'local-1\'',
        )
        .get();
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
    expect(
      gateway.accepted.single.operation.operationId,
      operation.operationId,
    );
    expect(rebaseObserved, isEmpty);
    final rows = await database
        .customSelect('SELECT id FROM projection_probe')
        .get();
    expect(rows, hasLength(1));
    expect(await store.checkpoint('user-A-v2'), 1);
  });

  test('incoming update rebases with all pending local edits', () async {
    final localEdit = await local('local-pending');
    gateway.seed(_remote('actor-remote', 'remote-added'));

    await engine.start();
    expect(rebaseObserved.single, [localEdit.operationId]);
    final rows = await database
        .customSelect('SELECT id FROM projection_probe ORDER BY id')
        .get();
    expect(rows.map((row) => row.read<String>('id')).toList(), [
      'local-pending',
      'remote-added',
    ]);
    expect(await store.pending(), isEmpty);
  });

  test(
    'failed projection leaves cursor in place but not other documents',
    () async {
      gateway.seed(_remote('actor-broken', 'bad'));
      gateway.seed(_remote('actor-good', 'good', documentId: 'document-other'));
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
      expect(
        await store.operation(gateway.accepted.last.operation.operationId),
        isNotNull,
      );

      fail = false;
      await engine.syncNow();
      expect(await store.checkpoint('user-A-v2'), 2);
      final rows = await database
          .customSelect('SELECT id FROM projection_probe')
          .get();
      expect(rows, hasLength(2));
    },
  );

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
    expect(first.actorId, engine.actorIdForDocument('document-one'));
    expect(second.actorId, engine.actorIdForDocument('document-two'));
    expect(second.dependencies, isNot(contains(first.operationId)));
  });

  test(
    'history actor lookup preserves the existing document actor encoding',
    () {
      expect(
        engine.actorIdForDocument('document-one'),
        '994ee16e52a1361eabf1528db04575617bac67bdd7fc51e2b447bf8d91e4d4ea',
      );
      expect(engine.actorIdForDocument('document-one'), isNot(engine.actorId));
      expect(() => engine.actorIdForDocument(''), throwsArgumentError);
    },
  );

  test('a bad later operation cannot block a valid batch prefix', () async {
    await engine.stop();
    engine.dispose();
    final poisoned = _PoisonBatchGateway();
    engine = SyncEngine(
      store: store,
      gateway: poisoned,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (_, __) async {},
    );
    final valid = await engine.writeLocal(
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'good',
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {'name': 'good'},
      },
      apply: (_) async {},
    );
    final invalid = await engine.writeLocal(
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'bad',
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {'name': 'bad'},
      },
      apply: (_) async {},
    );
    await engine.start();
    expect(await store.isPending(valid.operationId), isFalse);
    expect(await store.isPending(invalid.operationId), isTrue);
    expect(await store.blockedReason(invalid.operationId), contains('422'));
    expect(poisoned.accepted.single.operation.operationId, valid.operationId);
  });

  test('a broken pull does not block the outbox of another document', () async {
    gateway.seed(_remote('actor-bad', 'bad'));
    await engine.stop();
    engine.dispose();
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (remote, _) async {
        if (remote.objectId == 'bad') {
          throw StateError('Broken projection');
        }
      },
    );
    final valid = await engine.writeLocal(
      documentId: 'document-other',
      pageId: 'page-other',
      objectId: 'valid',
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {'name': 'valid'},
      },
      apply: (_) => database.customStatement(
        'INSERT INTO projection_probe VALUES (?, ?)',
        ['valid', 'local'],
      ),
    );
    await engine.start();
    expect(gateway.cursors, contains(valid.operationId));
    expect(await store.isPending(valid.operationId), isFalse);
    expect(await store.checkpoint('user-A-v2'), 0);
  });

  test('an earlier actor retry is not hidden by a five-minute retry', () async {
    await engine.stop();
    engine.dispose();
    engine = SyncEngine(
      store: store,
      gateway: _RetryGateway(),
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (_, __) async {},
    );
    Future<void> addFor(String documentId) async {
      await engine.writeLocal(
        documentId: documentId,
        pageId: 'page',
        objectId: documentId,
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {'name': 'entry'},
        },
        apply: (_) async {},
      );
    }

    await addFor('document-one');
    await addFor('document-two');
    await engine.start();
    final deadline = engine.retryDeadline;
    expect(deadline, isNotNull);
    expect(deadline!.difference(DateTime.now()).inSeconds, lessThan(60));
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
      (await store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
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
  test(
    'remote UI patches run after SQLite commit and retry on failure',
    () async {
      gateway.seed(_remote('other-actor', 'remote-patch'));
      engine.dispose();
      var attempts = 0;
      var allowDisplay = false;
      engine = SyncEngine(
        store: store,
        gateway: gateway,
        actorId: 'actor-local',
        checkpointScope: 'user-A-v2',
        enableRealtime: false,
        applyRemote: (remote, _) => database.customStatement(
          'INSERT INTO projection_probe VALUES (?, ?)',
          [remote.objectId, 'committed'],
        ),
        onRemoteCommitted: (remote) async {
          attempts++;
          final rows = await database
              .customSelect(
                'SELECT value FROM projection_probe WHERE id = ?',
                variables: [Variable<String>(remote.objectId!)],
              )
              .get();
          expect(rows.single.read<String>('value'), 'committed');
          if (!allowDisplay) {
            throw StateError('Editor is busy with a local gesture.');
          }
        },
      );
      await engine.start();
      expect(await store.checkpoint('user-A-v2'), 0);
      expect(attempts, greaterThanOrEqualTo(1));
      expect(engine.lastError, isNotNull);
      allowDisplay = true;
      await engine.syncNow();
      expect(await store.checkpoint('user-A-v2'), 1);
      expect(engine.lastError, isNull);
      expect(attempts, greaterThanOrEqualTo(2));
      final rows = await database
          .customSelect(
            'SELECT value FROM projection_probe WHERE id = ?',
            variables: [const Variable<String>('remote-patch')],
          )
          .get();
      expect(rows, hasLength(1));
    },
  );

  test(
    'asset bytes are prepared before the remote SQLite transaction',
    () async {
      final asset = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'asset-actor',
        actorSeq: 1,
        logicalClock: 1,
        dependencies: const [],
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'remote-image',
        kind: OperationKind.assetAttach,
        payload: const {
          'assetId': 'asset-one',
          'sha256':
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'sizeBytes': 12,
          'mediaType': 'image/png',
        },
      );
      gateway.seed(asset);
      engine.dispose();
      var prepared = 0;
      var committed = 0;
      engine = SyncEngine(
        store: store,
        gateway: gateway,
        actorId: 'actor-local',
        checkpointScope: 'user-A-v2',
        enableRealtime: false,
        prepareRemoteOperation: (operation) async {
          expect(operation.operationId, asset.operationId);
          expect(await store.operation(asset.operationId), isNull);
          final before = await database
              .customSelect('SELECT id FROM projection_probe')
              .get();
          expect(before, isEmpty);
          prepared++;
        },
        applyRemote: (operation, pending) async {
          expect(prepared, 1);
          await database.customStatement(
            'INSERT INTO projection_probe VALUES (?, ?)',
            [operation.objectId, 'committed'],
          );
          committed++;
        },
      );
      await engine.start();
      expect(prepared, 1);
      expect(committed, 1);
      expect(await store.checkpoint('user-A-v2'), 1);

      // A replay of the same committed op must not fetch the image again.
      await database.customStatement(
        'UPDATE sync_checkpoints SET server_sequence = 0 WHERE scope = ?',
        ['user-A-v2'],
      );
      await engine.syncNow();
      expect(prepared, 1);
      expect(committed, 1);
      expect(await store.checkpoint('user-A-v2'), 1);
    },
  );

  test(
    'replacement is prepared before remote projection and after restart',
    () async {
      final replacement = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'image-switch-actor',
        actorSeq: 1,
        logicalClock: 1,
        dependencies: const [],
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'image-to-replace',
        kind: OperationKind.objectSet,
        payload: const {
          'properties': {'assetId': 'verified-replacement'},
        },
      );
      gateway.seed(replacement);
      engine.dispose();
      var prepared = 0;
      var committed = 0;
      engine = SyncEngine(
        store: store,
        gateway: gateway,
        actorId: 'actor-local',
        checkpointScope: 'user-A-v2',
        enableRealtime: false,
        prepareRemoteOperation: (operation) async {
          expect(operation.operationId, replacement.operationId);
          expect(await store.operation(replacement.operationId), isNull);
          prepared++;
        },
        applyRemote: (operation, pending) async {
          expect(prepared, 1);
          await database.customStatement(
            'INSERT INTO projection_probe VALUES (?, ?)',
            [operation.objectId, 'switched'],
          );
          committed++;
        },
      );
      await engine.start();
      expect(prepared, 1);
      expect(committed, 1);
      expect(await store.checkpoint('user-A-v2'), 1);

      await database.customStatement(
        'UPDATE sync_checkpoints SET server_sequence = 0 WHERE scope = ?',
        ['user-A-v2'],
      );
      await engine.syncNow();
      expect(prepared, 1);
      expect(committed, 1);
    },
  );

  test('deleted media target never triggers stale verified download', () async {
    const doc = 'document-one';
    const page = 'page-one';
    const object = 'deleted-media';
    final created = await store.writeLocal(
      actorId: 'tombstone-actor',
      documentId: doc,
      kind: OperationKind.objectCreate,
      pageId: page,
      objectId: object,
      payload: const {
        'value': {'objectType': 'image'},
      },
      apply: (_) async {},
    );
    await store.writeLocal(
      actorId: 'tombstone-actor',
      documentId: doc,
      kind: OperationKind.objectDelete,
      pageId: page,
      objectId: object,
      payload: const {},
      dependencies: [created.operationId],
      apply: (_) async {},
    );
    final stale = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'late-remote-media',
      actorSeq: 1,
      logicalClock: 1,
      dependencies: const [],
      documentId: doc,
      pageId: page,
      objectId: object,
      kind: OperationKind.assetAttach,
      payload: const {
        'assetId': 'deleted-asset',
        'sha256':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'sizeBytes': 12,
        'mediaType': 'image/png',
      },
    );
    gateway.seed(stale);
    engine.dispose();
    var downloaded = 0;
    var applied = 0;
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      prepareRemoteOperation: (_) async {
        downloaded++;
        throw StateError('Deleted image must not download.');
      },
      applyRemote: (operation, pending) async {
        applied++;
      },
    );
    await engine.start();
    expect(downloaded, 0);
    expect(applied, 0);
    expect(await store.operation(stale.operationId), isNotNull);
    // The gateway also accepts and echoes two queued local tombstone edits.
    // The third feed row is the stale remote media operation.
    expect(gateway.accepted, hasLength(3));
    expect(await store.checkpoint('user-A-v2'), 3);
  });

  test('a replayed remote operation notifies the editor once', () async {
    gateway.seed(_remote('other-actor', 'remote-once'));
    engine.dispose();
    var notifications = 0;
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (remote, _) => database.customStatement(
        'INSERT INTO projection_probe VALUES (?, ?)',
        [remote.objectId, 'committed'],
      ),
      onRemoteCommitted: (remote) async {
        notifications++;
        expect(remote.objectId, 'remote-once');
      },
    );
    await engine.start();
    expect(notifications, 1);
    expect(await store.checkpoint('user-A-v2'), 1);

    // A later feed gap can force a cursor replay without rolling back
    // the already committed SQLite projection or remounting the editor.
    await database.customStatement(
      'UPDATE sync_checkpoints SET server_sequence = 0 WHERE scope = ?',
      ['user-A-v2'],
    );
    await engine.syncNow();
    expect(await store.checkpoint('user-A-v2'), 1);
    expect(notifications, 1);
    await engine.stop();
    await database.customStatement(
      'UPDATE sync_checkpoints SET server_sequence = 0 WHERE scope = ?',
      ['user-A-v2'],
    );
    await engine.start();
    // A new editor session can rebuild the view from its durable projection.
    expect(notifications, 2);
    final rows = await database
        .customSelect('SELECT id FROM projection_probe')
        .get();
    expect(rows, hasLength(1));
  });

  test('an ACKed local echo cannot repaint after cursor replay', () async {
    engine.dispose();
    var notifications = 0;
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (_, _) async {},
      onRemoteCommitted: (_) async {
        notifications++;
      },
    );
    final created = await local('own-stroke');
    await engine.start();
    expect(await store.isPending(created.operationId), isFalse);
    expect(await store.isLocalOperation(created.operationId), isTrue);
    expect(notifications, 0);
    // ACK and global checkpoint live in separate transactions. Simulate a
    // checkpoint restored before the already-confirmed local journal entry.
    await database.customStatement(
      'UPDATE sync_checkpoints SET server_sequence = 0 WHERE scope = ?',
      ['user-A-v2'],
    );
    await engine.syncNow();
    expect(await store.checkpoint('user-A-v2'), 1);
    expect(notifications, 0);
  });

  test('HTTP 410 stops Share and preserves offline outbox', () async {
    await engine.stop();
    engine.dispose();
    var ended = 0;
    const ticket = '01234567890123456789012345678901234567890123456789';
    engine = SyncEngine(
      store: store,
      gateway: _RevokedShareGateway(),
      actorId: 'guest-instance',
      checkpointScope: 'share-guest-1',
      shareId: '11111111-1111-4111-8111-111111111111',
      guestTicket: ticket,
      onShareEnded: () => ended++,
      enableRealtime: false,
      applyRemote: (_, __) async {},
    );
    final pending = await engine.writeLocal(
      documentId: 'document-one',
      pageId: 'page-one',
      objectId: 'offline-stroke',
      kind: OperationKind.strokeCreate,
      payload: const {
        'value': {'colorValue': 1},
      },
      apply: (_) async {},
    );
    expect(await store.isPending(pending.operationId), isTrue);
    await engine.start();
    expect(ended, 1);
    expect(engine.isStarted, isFalse);
    expect(await store.isPending(pending.operationId), isTrue);
  });
}
