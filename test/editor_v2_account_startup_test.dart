import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_v2_account_runtime.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

import 'support/native_test_documents.dart';

class _Fixture {
  _Fixture(QueryExecutor executor, {this.beforeFeed}) {
    database = NotesDatabase(executor);
    repository = NotebookRepository(database);
    api = ApiClient(
      baseUri: Uri.parse('http://127.0.0.1:9'),
      httpClient: MockClient(_handle),
    )..setAccessToken('test-access-token');
    runtime = EditorV2AccountRuntime(
      repository: repository,
      apiClient: api,
      accountId: 'startup-account',
      actorId: 'startup-device',
      // REST is stubbed; these ownership tests never start a real WS server.
      // Real transport and reconnect are exercised by Linux E2E.
      enableRealtime: false,
    );
  }
  final Future<void> Function()? beforeFeed;
  late final NotesDatabase database;
  late final NotebookRepository repository;
  late final ApiClient api;
  late final EditorV2AccountRuntime runtime;
  final requests = <http.Request>[];
  final accepted = <Map<String, dynamic>>[];
  bool rejectPosts = false;

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    if (request.method == 'GET' && request.url.path == '/v2/operations') {
      await beforeFeed?.call();
      final after = int.parse(request.url.queryParameters['after']!);
      return http.Response(
        jsonEncode({
          'cursor': accepted.length,
          'hasMore': false,
          'operations': [
            for (var index = after; index < accepted.length; index++)
              {'cursor': index + 1, 'operation': accepted[index]},
          ],
        }),
        200,
      );
    }
    if (request.method == 'POST' &&
        request.url.path == '/v2/operations/batch') {
      if (rejectPosts) {
        return http.Response('Temporary outage', 503);
      }
      final operations =
          (jsonDecode(request.body) as Map)['operations'] as List;
      final acks = <Map<String, dynamic>>[];
      for (final raw in operations) {
        final operation = Map<String, dynamic>.from(raw as Map);
        var index = accepted.indexWhere(
          (op) => op['operationId'] == operation['operationId'],
        );
        final duplicate = index >= 0;
        if (!duplicate) {
          accepted.add(operation);
          index = accepted.length - 1;
        }
        acks.add({
          'operationId': operation['operationId'],
          'cursor': index + 1,
          'status': duplicate ? 'duplicate' : 'applied',
        });
      }
      return http.Response(
        jsonEncode({'cursor': accepted.length, 'acknowledgements': acks}),
        200,
      );
    }
    throw StateError(
      'Unexpected startup request: ${request.method} ${request.url.path}',
    );
  }

  Future<void> close() async {
    await runtime.stop();
    runtime.dispose();
    api.close();
    await database.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  test('obsolete account cannot bind the repository or start HTTP', () async {
    final fixture = _Fixture(NativeDatabase.memory());
    addTearDown(fixture.close);
    expect(
      await fixture.runtime.startForCurrentAccount(isCurrent: () => false),
      isFalse,
    );
    expect(fixture.requests, isEmpty);
    await fixture.repository.createNotebook();
    expect(
      await fixture.database.customSelect('SELECT * FROM operations').get(),
      isEmpty,
    );
  });

  test(
    'cancellation during repository readiness cannot start transport',
    () async {
      final opening = Completer<void>();
      final entered = Completer<void>();
      final fixture = _Fixture(
        LazyDatabase(() async {
          entered.complete();
          await opening.future;
          return NativeDatabase.memory();
        }),
      );
      addTearDown(() async {
        if (!opening.isCompleted) {
          opening.complete();
        }
        await fixture.close();
      });
      var current = true;
      final started = fixture.runtime.startForCurrentAccount(
        isCurrent: () => current,
      );
      await entered.future;
      current = false;
      opening.complete();
      expect(await started, isFalse);
      expect(fixture.requests, isEmpty);
      final notebook = await fixture.repository.createNotebook();
      expect(await fixture.runtime.store.pending(), hasLength(2));
      await expectLater(
        fixture.repository.saveNotebook(notebook),
        throwsStateError,
      );
    },
  );

  test(
    'cancellation during REST startup stops the old engine and permits retry',
    () async {
      final entered = Completer<void>();
      final response = Completer<void>();
      final fixture = _Fixture(
        NativeDatabase.memory(),
        beforeFeed: () async {
          if (!entered.isCompleted) {
            entered.complete();
          }
          await response.future;
        },
      );
      addTearDown(() async {
        if (!response.isCompleted) {
          response.complete();
        }
        await fixture.close();
      });
      var current = true;
      final started = fixture.runtime.startForCurrentAccount(
        isCurrent: () => current,
      );
      await entered.future;
      current = false;
      response.complete();
      expect(await started, isFalse);
      final count = fixture.requests.length;
      await fixture.runtime.engine.syncNow();
      expect(fixture.requests, hasLength(count));
      current = true;
      expect(
        await fixture.runtime.startForCurrentAccount(isCurrent: () => current),
        isTrue,
      );
      expect(fixture.requests.length, greaterThan(count));
    },
  );

  test(
    'same writer is idempotent with an active editor and queued operations',
    () async {
      final fixture = _Fixture(NativeDatabase.memory());
      addTearDown(fixture.close);
      await fixture.repository.enableAccountOperations(fixture.runtime.writer);
      final notebook = await fixture.repository.createNotebook();
      final editor = EditorController(
        repository: fixture.repository,
        notebook: notebook,
        operationWriter: fixture.runtime.writer,
      );
      addTearDown(editor.dispose);
      await editor.historyReady;
      await editor.preferencesReady;
      fixture.runtime.attachEditor(editor);
      await fixture.repository.enableAccountOperations(fixture.runtime.writer);
      expect(
        await fixture.runtime.startForCurrentAccount(isCurrent: () => true),
        isTrue,
      );
      expect(
        await fixture.runtime.store.pending(includeDeferred: true),
        isEmpty,
      );
      expect(fixture.accepted, hasLength(2));
      await expectLater(
        fixture.repository.saveNotebook(notebook),
        throwsStateError,
      );
      await fixture.runtime.stop();
      expect(
        await fixture.runtime.startForCurrentAccount(isCurrent: () => true),
        isTrue,
      );
      expect(fixture.accepted, hasLength(2));
      fixture.runtime.detachEditor(editor);
    },
  );

  test('an obsolete owner also stops an already started runtime', () async {
    final fixture = _Fixture(NativeDatabase.memory());
    addTearDown(fixture.close);
    expect(
      await fixture.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    expect(
      await fixture.runtime.startForCurrentAccount(isCurrent: () => false),
      isFalse,
    );
    final count = fixture.requests.length;
    await fixture.runtime.engine.syncNow();
    expect(fixture.requests, hasLength(count));
  });

  test(
    'an owner cancelled while the prior engine drains cannot send REST',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final fixture = _Fixture(
        NativeDatabase.memory(),
        beforeFeed: () async {
          if (!entered.isCompleted) {
            entered.complete();
          }
          await release.future;
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) {
          release.complete();
        }
        await fixture.close();
      });
      await fixture.repository.enableAccountOperations(fixture.runtime.writer);
      final oldStart = fixture.runtime.start();
      await entered.future;
      final stopping = fixture.runtime.stop();
      final afterValidation = Completer<void>();
      var current = true;
      var checks = 0;
      final restart = fixture.runtime.startForCurrentAccount(
        isCurrent: () {
          checks++;
          if (checks == 2) {
            afterValidation.complete();
          }
          return current;
        },
      );
      await afterValidation.future.timeout(const Duration(seconds: 1));
      current = false;
      release.complete();
      await stopping.timeout(const Duration(seconds: 1));
      await oldStart;
      expect(await restart, isFalse);
      expect(fixture.requests, hasLength(1));
      expect(fixture.requests.single.method, 'GET');
    },
  );

  test(
    'legacy validation preserves data and retries after explicit cleanup',
    () async {
      final fixture = _Fixture(NativeDatabase.memory());
      addTearDown(fixture.close);
      final notebook = await fixture.repository.createNotebook();
      await expectLater(
        fixture.runtime.startForCurrentAccount(isCurrent: () => true),
        throwsStateError,
      );
      expect(fixture.requests, isEmpty);
      expect(
        (await fixture.repository.getNotebook(notebook.uid))!.uid,
        notebook.uid,
      );
      expect(
        await fixture.database.customSelect('SELECT * FROM operations').get(),
        isEmpty,
      );
      // Only the test removes the legacy fixture; startup never migrates it.
      await fixture.repository.deleteNotebook(notebook.uid);
      expect(
        await fixture.runtime.startForCurrentAccount(isCurrent: () => true),
        isTrue,
      );
      expect(fixture.requests, isNotEmpty);
    },
  );

  test(
    'repeated binding waits for the same validation instead of bypassing it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nn-account-startup-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/notes.sqlite');
      final original = NotesDatabase(NativeDatabase(file));
      await NotebookRepository(original).createNotebook();
      await original.close();
      final opening = Completer<void>();
      final entered = Completer<void>();
      final fixture = _Fixture(
        LazyDatabase(() async {
          entered.complete();
          await opening.future;
          return NativeDatabase(file);
        }),
      );
      addTearDown(() async {
        if (!opening.isCompleted) {
          opening.complete();
        }
        await fixture.close();
      });
      final first = fixture.repository.enableAccountOperations(
        fixture.runtime.writer,
      );
      final firstCheck = expectLater(first, throwsStateError);
      await entered.future;
      var settled = false;
      final second = fixture.repository.enableAccountOperations(
        fixture.runtime.writer,
      );
      final secondCheck = expectLater(
        second,
        throwsStateError,
      ).whenComplete(() => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      opening.complete();
      await Future.wait([firstCheck, secondCheck]);
      expect(fixture.requests, isEmpty);
      expect(
        await fixture.database.customSelect('SELECT * FROM operations').get(),
        isEmpty,
      );
    },
  );

  test(
    'another runtime cannot replace an account writer after startup',
    () async {
      final fixture = _Fixture(NativeDatabase.memory());
      addTearDown(fixture.close);
      expect(
        await fixture.runtime.startForCurrentAccount(isCurrent: () => true),
        isTrue,
      );
      await fixture.runtime.stop();
      final other = EditorV2AccountRuntime(
        repository: fixture.repository,
        apiClient: fixture.api,
        accountId: 'other-account',
        actorId: 'other-device',
      );
      addTearDown(other.dispose);
      final count = fixture.requests.length;
      await expectLater(
        other.startForCurrentAccount(isCurrent: () => true),
        throwsStateError,
      );
      expect(fixture.requests, hasLength(count));
      final notebook = await fixture.repository.createNotebook();
      expect(await fixture.runtime.store.pending(), hasLength(2));
      await expectLater(
        fixture.repository.saveNotebook(notebook),
        throwsStateError,
      );
    },
  );
  test('offline independent merge keeps same-object conflicts', () async {
    final fixture = _Fixture(NativeDatabase.memory());
    addTearDown(fixture.close);
    expect(
      await fixture.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final notebook = await fixture.repository.createNotebook();
    await fixture.runtime.engine.syncNow();
    expect(fixture.accepted, hasLength(2));
    final pageId = notebook.pages.single.id;
    const strokePayload = {
      'value': {
        'objectType': 'stroke',
        'colorValue': 0xFF123456,
        'width': 2.0,
        'toolIndex': 0,
        'sortIndex': 0,
        'points': [
          [1.0, 2.0, 0.5],
        ],
      },
    };
    final local = await fixture.runtime.store.writeLocal(
      actorId: fixture.runtime.engine.actorIdForDocument(notebook.uid),
      documentId: notebook.uid,
      kind: OperationKind.strokeCreate,
      pageId: pageId,
      objectId: 'offline-stroke',
      payload: strokePayload,
      apply: fixture.runtime.projector.apply,
    );
    fixture.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000000501',
      actorId: 'other-device',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [fixture.accepted.last['operationId'] as String],
      documentId: notebook.uid,
      pageId: pageId,
      objectId: 'peer-stroke',
      kind: OperationKind.strokeCreate,
      payload: strokePayload,
    );
    fixture.accepted.add(remote.toJson());
    await fixture.runtime.engine.syncNow();
    final first = (await fixture.repository.getNotebook(notebook.uid))!;
    expect(
      first.pages.single.inkStrokes.map((stroke) => stroke.id).toSet(),
      {'offline-stroke', 'peer-stroke'},
    );
    expect(
      await fixture.runtime.store.checkpoint('account:startup-account'),
      3,
    );
    expect(
      (await fixture.runtime.store.pending(includeDeferred: true))
          .map((operation) => operation.operationId),
      [local.operationId],
    );

    final localSet = await fixture.runtime.store.writeLocal(
      actorId: fixture.runtime.engine.actorIdForDocument(notebook.uid),
      documentId: notebook.uid,
      kind: OperationKind.objectSet,
      pageId: pageId,
      objectId: remote.objectId,
      payload: const {
        'properties': {'width': 3.0},
      },
      apply: fixture.runtime.projector.apply,
    );
    final competing = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000000502',
      actorId: 'other-device',
      actorSeq: 2,
      logicalClock: localSet.logicalClock + 1,
      dependencies: [remote.operationId],
      documentId: notebook.uid,
      pageId: pageId,
      objectId: remote.objectId,
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'width': 4.0},
      },
    );
    fixture.accepted.add(competing.toJson());
    await fixture.runtime.engine.syncNow();
    expect(
      await fixture.runtime.store.checkpoint('account:startup-account'),
      3,
    );
    expect(
      await fixture.runtime.store.operation(competing.operationId),
      isNull,
    );
    final afterConflict = (await fixture.repository.getNotebook(notebook.uid))!;
    expect(
      afterConflict.pages.single.inkStrokes
          .singleWhere((stroke) => stroke.id == remote.objectId)
          .width,
      3.0,
    );
    expect(
      (await fixture.runtime.store.pending(includeDeferred: true))
          .map((operation) => operation.operationId),
      [local.operationId, localSet.operationId],
    );
  });

}
