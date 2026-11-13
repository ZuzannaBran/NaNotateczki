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
import 'package:web_socket_channel/io.dart';

class _FakeGateway implements OperationGateway {
  final List<SequencedOperation> accepted = [];
  final Map<String, int> cursors = {};
  final List<List<String>> batches = [];
  bool dropNextAck = false;
  int reads = 0;

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
    reads++;
    final unread = accepted.where((entry) => entry.cursor > cursor).toList();
    return OperationFeedPage(
      cursor: unread.isEmpty ? cursor : unread.last.cursor,
      hasMore: false,
      operations: unread,
    );
  }
}

class _PagedFeedGateway extends _FakeGateway {
  bool verifyPrefix = false;

  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    reads++;
    final unread = accepted.where((item) => item.cursor > cursor).toList();
    if (unread.isEmpty) {
      return OperationFeedPage(
        cursor: cursor,
        hasMore: false,
        operations: const [],
      );
    }
    return OperationFeedPage(
      cursor: unread.first.cursor,
      hasMore: unread.length > 1,
      operations: [unread.first],
      verifiedVisiblePrefix: verifyPrefix,
    );
  }
}

class _HeldFeedGateway extends _FakeGateway {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    if (!entered.isCompleted) {
      entered.complete();
    }
    await release.future;
    return super.readAfter(cursor);
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

class _QuietFeedGateway extends _FakeGateway {
  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    reads++;
    return OperationFeedPage(
      cursor: cursor,
      hasMore: false,
      operations: const [],
    );
  }
}

class _MalformedFeedGateway extends _FakeGateway {
  _MalformedFeedGateway(this.page);

  final OperationFeedPage page;

  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    reads++;
    return page;
  }
}

/// A complete visible feed must not replay its last row after checkpointing.
class _FilteredFeedGateway extends _MalformedFeedGateway {
  _FilteredFeedGateway(super.page);

  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    if (cursor >= page.cursor) {
      reads++;
      return OperationFeedPage(
        cursor: cursor,
        hasMore: false,
        operations: const [],
        verifiedVisiblePrefix: page.verifiedVisiblePrefix,
      );
    }
    return super.readAfter(cursor);
  }
}

class _ReversedAckGateway extends _QuietFeedGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    batches.add(operations.map((op) => op.operationId).toList());
    return [
      for (var index = 0; index < operations.length; index++)
        OperationReceipt(operations[index].operationId, 92 - index),
    ];
  }
}

class _OversizedAckGateway extends _QuietFeedGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    batches.add(operations.map((op) => op.operationId).toList());
    return [
      for (final operation in operations)
        OperationReceipt(
          operation.operationId,
          OperationEnvelope.maxSafeInteger + 1,
        ),
    ];
  }
}

class _DuplicateAckGateway extends _FakeGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    batches.add(operations.map((op) => op.operationId).toList());
    return [
      for (final operation in operations)
        OperationReceipt(operation.operationId, 77),
    ];
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

  test('blocked document does not starve later feed pages', () async {
    await engine.stop();
    engine.dispose();
    gateway = _PagedFeedGateway();
    gateway.seed(_remote('broken-actor', 'blocked-object'));
    gateway.seed(
      _remote('healthy-actor', 'healthy-object', documentId: 'other-document'),
    );
    var canApply = false;
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (operation, pending) async {
        if (operation.objectId == 'blocked-object' && !canApply) {
          throw StateError('Needs explicit conflict resolution.');
        }
        await database.customStatement(
          'INSERT INTO projection_probe VALUES (?, ?)',
          [operation.objectId!, 'remote'],
        );
      },
    );
    await engine.start();
    expect(await store.checkpoint('user-A-v2'), 0);
    expect(
      await store.operation(gateway.accepted[0].operation.operationId),
      isNull,
    );
    expect(
      await store.operation(gateway.accepted[1].operation.operationId),
      isNotNull,
    );
    expect(gateway.reads, greaterThanOrEqualTo(2));
    expect(
      (await database.customSelect('SELECT * FROM projection_probe').get()),
      hasLength(1),
    );
    canApply = true;
    await engine.syncNow();
    expect(await store.checkpoint('user-A-v2'), 2);
    expect(
      (await database.customSelect('SELECT * FROM projection_probe').get()),
      hasLength(2),
    );
  });

  test('an unrelated compact frontier crosses a verified feed gap', () async {
    await engine.stop();
    engine.dispose();
    final paged = _PagedFeedGateway()..verifyPrefix = true;
    paged.seed(_remote('broken', 'blocked'));
    final healthy = OperationEnvelope.fromJson({
      ..._remote('healthy', 'kept', documentId: 'independent').toJson(),
      'causalCursor': 1,
    });
    paged.seed(healthy);
    engine = SyncEngine(
      store: store,
      gateway: paged,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (op, _) async {
        if (op.objectId == 'blocked') {
          throw StateError('Conflict in another document.');
        }
      },
    );
    await engine.start();
    expect(await store.operation(healthy.operationId), isNotNull);
    expect(await store.checkpoint('user-A-v2'), 0);
  });

  test(
    'blocked local intent can be retried without rewriting identity',
    () async {
      final intent = await local('recoverable');
      await store.markBlocked(intent.operationId, 'manual intervention');
      expect(await store.pending(), isEmpty);
      expect(await store.blockedReason(intent.operationId), isNotNull);
      await engine.retryBlockedOperation(intent.operationId);
      expect(await store.blockedReason(intent.operationId), isNull);
      final queued = await store.pending();
      expect(queued.single.toJson(), intent.toJson());
      await engine.start();
      expect(await store.pending(), isEmpty);
    },
  );

  test('malformed feed pages cannot commit valid-looking prefixes', () async {
    final first = _remote('remote-peer', 'bad-feed-first');
    final second = _remote('remote-peer', 'bad-feed-second');
    final malformed = [
      OperationFeedPage(
        cursor: 2,
        hasMore: false,
        operations: [SequencedOperation(1, first)],
      ),
      OperationFeedPage(
        cursor: 1,
        hasMore: false,
        operations: [
          SequencedOperation(1, first),
          SequencedOperation(1, second),
        ],
      ),
      const OperationFeedPage(cursor: 0, hasMore: true, operations: []),
      OperationFeedPage(
        cursor: OperationEnvelope.maxSafeInteger + 1,
        hasMore: false,
        operations: const [],
      ),
    ];
    for (final page in malformed) {
      await engine.stop();
      engine.dispose();
      gateway = _MalformedFeedGateway(page);
      engine = SyncEngine(
        store: store,
        gateway: gateway,
        actorId: 'actor-local',
        checkpointScope: 'user-A-v2',
        enableRealtime: false,
        applyRemote: (remote, _) async {
          await database.customStatement(
            'INSERT INTO projection_probe VALUES (?, ?)',
            [remote.objectId, 'remote'],
          );
        },
      );
      await engine.start();
      expect(
        (await database.customSelect('SELECT * FROM projection_probe').get()),
        isEmpty,
      );
      expect(await store.checkpoint('user-A-v2'), 0);
      expect(engine.lastError, contains('feed'));
    }
  });

  test(
    'filtered REST prefix covers invisible cursors, not unverified gaps',
    () async {
      final remote = OperationEnvelope.fromJson({
        ..._remote('share-peer', 'share-object').toJson(),
        'causalCursor': 4,
        'logicalClock': 5,
      });
      Future<void> usePage(bool verified) async {
        await engine.stop();
        engine.dispose();
        gateway = _FilteredFeedGateway(
          OperationFeedPage(
            cursor: 5,
            hasMore: false,
            operations: [SequencedOperation(5, remote)],
            verifiedVisiblePrefix: verified,
          ),
        );
        engine = SyncEngine(
          store: store,
          gateway: gateway,
          actorId: 'share-client',
          checkpointScope: 'user-A-v2',
          enableRealtime: false,
          applyRemote: (op, _) async {
            await database.customStatement(
              'INSERT INTO projection_probe VALUES (?, ?)',
              [op.objectId, 'remote'],
            );
          },
        );
        await engine.start();
      }

      await usePage(false);
      expect(await store.operation(remote.operationId), isNull);
      expect(await store.checkpoint('user-A-v2'), 0);
      expect(engine.lastError, contains('gap'));

      await usePage(true);
      expect(await store.operation(remote.operationId), isNotNull);
      expect(await store.checkpoint('user-A-v2'), 5);
      expect(engine.lastError, isNull);
      final completedPage = await gateway.readAfter(5);
      expect(completedPage.cursor, 5);
      expect(completedPage.operations, isEmpty);
    },
  );

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
        applyRemote: (_, _) async {},
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

  test(
    'stalled handshake cannot block stop or corrupt the next generation',
    () async {
      await engine.stop();
      engine.dispose();
      final api = ApiClient(baseUri: Uri.parse('http://127.0.0.1:9'))
        ..setAccessToken('test-token');
      addTearDown(api.close);
      final handshakes = <Completer<WebSocket>>[];
      final ready = <Future<void>>[];
      engine = SyncEngine(
        store: store,
        gateway: gateway,
        actorId: 'stalled-handshake',
        checkpointScope: 'stalled-handshake',
        apiClient: api,
        connectRealtime: (uri) {
          expect(uri.path, '/v2/realtime');
          final handshake = Completer<WebSocket>();
          handshakes.add(handshake);
          final channel = IOWebSocketChannel(handshake.future);
          ready.add(channel.ready.catchError((Object _) {}));
          return channel;
        },
        applyRemote: (_, _) async {},
      );
      addTearDown(() async {
        for (final handshake in handshakes) {
          if (!handshake.isCompleted) {
            handshake.completeError(const SocketException('Test cleanup'));
          }
        }
        await Future.wait(ready);
        await engine.stop();
      });
      await engine.start();
      await engine.stop().timeout(const Duration(seconds: 1));
      await engine.start();
      expect(handshakes, hasLength(2));
      final before = gateway.reads;
      handshakes.first.completeError(const SocketException('Late old failure'));
      await ready.first;
      await engine.syncNow();
      expect(gateway.reads, greaterThan(before));
      expect(handshakes, hasLength(2));
      await engine.stop().timeout(const Duration(seconds: 1));
      final stoppedReads = gateway.reads;
      handshakes.last.completeError(const SocketException('Stopped failure'));
      await ready.last;
      await Future<void>.delayed(Duration.zero);
      expect(gateway.reads, stoppedReads);
    },
  );

  test(
    'stop still awaits in-flight REST and preserves its unsent outbox',
    () async {
      await engine.stop();
      engine.dispose();
      final held = _HeldFeedGateway();
      final handshake = Completer<WebSocket>();
      final channel = IOWebSocketChannel(handshake.future);
      final ready = channel.ready.catchError((Object _) {});
      final api = ApiClient(baseUri: Uri.parse('http://127.0.0.1:9'))
        ..setAccessToken('test-token');
      addTearDown(api.close);
      engine = SyncEngine(
        store: store,
        gateway: held,
        actorId: 'rest-drain',
        checkpointScope: 'rest-drain',
        apiClient: api,
        connectRealtime: (_) => channel,
        applyRemote: (_, _) async {},
      );
      addTearDown(() async {
        if (!held.release.isCompleted) {
          held.release.complete();
        }
        if (!handshake.isCompleted) {
          handshake.completeError(const SocketException('Test cleanup'));
        }
        await ready;
        await engine.stop();
      });
      final operation = await engine.writeLocal(
        documentId: 'document-one',
        pageId: 'page-one',
        objectId: 'pending',
        kind: OperationKind.objectCreate,
        payload: {
          'value': {'label': 'pending'},
        },
        apply: (_) async {},
      );
      final started = engine.start();
      await held.entered.future;
      var stopped = false;
      final drain = engine.stop();
      expect(identical(engine.stop(), drain), isTrue);
      final stopping = drain.then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      held.release.complete();
      await stopping.timeout(const Duration(seconds: 1));
      await started;
      expect(
        (await store.pending(
          includeDeferred: true,
        )).map((op) => op.operationId),
        [operation.operationId],
      );
      expect(held.accepted, isEmpty);
      handshake.completeError(const SocketException('Cancelled handshake'));
      await ready;
    },
  );

  test(
    'a restart waits for the previous REST drain and performs its own pull',
    () async {
      await engine.stop();
      engine.dispose();
      final held = _HeldFeedGateway();
      engine = SyncEngine(
        store: store,
        gateway: held,
        actorId: 'serial-restart',
        checkpointScope: 'serial-restart',
        enableRealtime: false,
        applyRemote: (_, _) async {},
      );
      addTearDown(() {
        if (!held.release.isCompleted) {
          held.release.complete();
        }
      });
      final first = engine.start();
      await held.entered.future;
      final stopping = engine.stop();
      var restarted = false;
      final restart = engine.start().then((_) => restarted = true);
      await Future<void>.delayed(Duration.zero);
      expect(restarted, isFalse);
      held.release.complete();
      await stopping;
      await first;
      await restart;
      expect(held.reads, 3);
      expect(restarted, isTrue);
    },
  );

  test(
    'an owner cancelled during the old drain cannot start a new pass',
    () async {
      await engine.stop();
      engine.dispose();
      final held = _HeldFeedGateway();
      engine = SyncEngine(
        store: store,
        gateway: held,
        actorId: 'cancelled-restart',
        checkpointScope: 'cancelled-restart',
        enableRealtime: false,
        applyRemote: (_, _) async {},
      );
      addTearDown(() {
        if (!held.release.isCompleted) {
          held.release.complete();
        }
      });
      final first = engine.start();
      await held.entered.future;
      final stopping = engine.stop();
      var current = true;
      final restart = engine.start(isCurrent: () => current);
      current = false;
      held.release.complete();
      await stopping;
      await first;
      await restart;
      expect(held.reads, 1);
      await engine.syncNow();
      expect(held.reads, 1);
    },
  );

  test('dispose prevents a restart queued behind the old REST drain', () async {
    await engine.stop();
    engine.dispose();
    final held = _HeldFeedGateway();
    engine = SyncEngine(
      store: store,
      gateway: held,
      actorId: 'disposed-restart',
      checkpointScope: 'disposed-restart',
      enableRealtime: false,
      applyRemote: (_, _) async {},
    );
    addTearDown(() {
      if (!held.release.isCompleted) {
        held.release.complete();
      }
    });
    final first = engine.start();
    await held.entered.future;
    final stopping = engine.stop();
    final restart = expectLater(engine.start(), throwsStateError);
    engine.dispose();
    held.release.complete();
    await stopping;
    await first;
    await restart;
    expect(held.reads, 1);
  });

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
      applyRemote: (_, _) async {},
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

  test(
    'image creation and attachment stay together across the batch limit',
    () async {
      await engine.stop();
      final drafts = <LocalOperationDraft>[
        for (var i = 0; i < SyncEngine.maxBatchSize - 1; i++)
          LocalOperationDraft(
            kind: OperationKind.objectCreate,
            pageId: 'page-one',
            objectId: 'prefix-$i',
            payload: const {
              'value': {'objectType': 'test'},
            },
          ),
        LocalOperationDraft(
          kind: OperationKind.objectCreate,
          pageId: 'page-one',
          objectId: 'image',
          payload: const {
            'value': {'objectType': 'image', 'assetId': 'asset-one'},
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.assetAttach,
          pageId: 'page-one',
          objectId: 'image',
          payload: {
            'assetId': 'asset-one',
            'sha256': 'a' * 64,
            'sizeBytes': 20,
            'mediaType': 'image/png',
          },
        ),
      ];
      final committed = await store.writeLocalBatch(
        actorId: 'image-pair',
        documentId: 'document-one',
        operations: drafts,
        apply: (_) async {},
      );
      await engine.start();
      expect(gateway.batches.map((item) => item.length), [49, 2]);
      expect(
        gateway.batches.last,
        committed.reversed
            .take(2)
            .toList()
            .reversed
            .map((op) => op.operationId),
      );
      expect(await store.pending(), isEmpty);
    },
  );

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
      applyRemote: (_, _) async {},
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
      applyRemote: (_, _) async {},
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

  test('failed later ACK rolls back the full pushed batch', () async {
    final first = await local('atomic-ack-first');
    final second = await local('atomic-ack-second');
    await database.customStatement(
      'CREATE TRIGGER fail_second_ack '
      'BEFORE INSERT ON operation_ack '
      "WHEN NEW.operation_id = '${second.operationId}' "
      "BEGIN SELECT RAISE(ABORT, 'injected ACK failure'); END",
    );
    engine.dispose();
    gateway = _QuietFeedGateway();
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (_, _) async {},
    );
    await engine.start();
    expect(
      (await store.pending(includeDeferred: true)).map((op) => op.operationId),
      [first.operationId, second.operationId],
    );
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      isEmpty,
    );
    expect(gateway.batches, hasLength(1));

    await database.customStatement('DROP TRIGGER fail_second_ack');
    await database.customStatement(
      'UPDATE operation_outbox '
      'SET retry_after = 0',
    );
    await engine.syncNow();
    expect(await store.pending(includeDeferred: true), isEmpty);
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      hasLength(2),
    );
    expect(gateway.batches, hasLength(2));
  });

  test('reversed actor ACK cursors preserve the complete outbox', () async {
    final first = await local('reversed-ack-first');
    final second = await local('reversed-ack-second');
    engine.dispose();
    gateway = _ReversedAckGateway();
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (_, _) async {},
    );
    await engine.start();
    expect(
      (await store.pending(includeDeferred: true)).map((op) => op.operationId),
      [first.operationId, second.operationId],
    );
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      isEmpty,
    );
    expect(await store.blockedReason(first.operationId), contains('ACK'));
    expect(gateway.batches, hasLength(1));
  });

  test('unsafe server ACK cursor leaves queued intent untouched', () async {
    final localOperation = await local('unsafe-server-cursor');
    engine.dispose();
    gateway = _OversizedAckGateway();
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (_, _) async {},
    );
    await engine.start();
    expect(await store.isPending(localOperation.operationId), isTrue);
    expect(
      await store.blockedReason(localOperation.operationId),
      contains('ACK'),
    );
    expect(
      (await database.customSelect('SELECT * FROM operation_ack').get()),
      isEmpty,
    );
    expect(await store.checkpoint('user-A-v2'), 0);
  });

  test('duplicate ACK cursors never delete queued local intents', () async {
    final first = await local('duplicate-ack-first');
    final second = await local('duplicate-ack-second');
    await engine.stop();
    engine.dispose();
    gateway = _DuplicateAckGateway();
    engine = SyncEngine(
      store: store,
      gateway: gateway,
      actorId: 'actor-local',
      checkpointScope: 'user-A-v2',
      enableRealtime: false,
      applyRemote: (_, _) async {},
    );
    await engine.start();
    expect(await store.isPending(first.operationId), isTrue);
    expect(await store.isPending(second.operationId), isTrue);
    expect(await store.blockedReason(first.operationId), contains('ACK'));
    expect(await store.checkpoint('user-A-v2'), 0);
    expect(gateway.batches, hasLength(1));
    expect(gateway.batches.single, [first.operationId, second.operationId]);
  });
}
