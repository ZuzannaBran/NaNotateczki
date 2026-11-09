import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show LazyDatabase, QueryExecutor;
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
  test('offline independent merge resolves scalar conflicts by rank', () async {
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
    expect(first.pages.single.inkStrokes.map((stroke) => stroke.id).toSet(), {
      'offline-stroke',
      'peer-stroke',
    });
    expect(
      await fixture.runtime.store.checkpoint('account:startup-account'),
      3,
    );
    expect(
      (await fixture.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
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
    final remoteColor = OperationEnvelope(
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
        'properties': {'colorValue': 0xFF345678},
      },
    );
    fixture.accepted.add(remoteColor.toJson());
    await fixture.runtime.engine.syncNow();
    expect(
      await fixture.runtime.store.checkpoint('account:startup-account'),
      4,
    );
    final updated = (await fixture.repository.getNotebook(notebook.uid))!;
    final merged = updated.pages.single.inkStrokes.singleWhere(
      (stroke) => stroke.id == remote.objectId,
    );
    expect(merged.width, 3.0);
    expect(merged.color.toARGB32(), 0xFF345678);

    final remoteShape = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000000503',
      actorId: 'other-device',
      actorSeq: 3,
      logicalClock: remoteColor.logicalClock + 1,
      dependencies: [remoteColor.operationId],
      documentId: notebook.uid,
      pageId: pageId,
      objectId: remote.objectId,
      kind: OperationKind.objectTransform,
      payload: const {
        'properties': {
          'points': [
            [10.0, 20.0, 0.5],
            [11.0, 21.0, 0.5],
          ],
        },
      },
    );
    fixture.accepted.add(remoteShape.toJson());
    await fixture.runtime.engine.syncNow();
    expect(
      await fixture.runtime.store.checkpoint('account:startup-account'),
      5,
    );
    final shapeNotebook = (await fixture.repository.getNotebook(notebook.uid))!;
    final afterShape = shapeNotebook.pages.single.inkStrokes.singleWhere(
      (stroke) => stroke.id == remote.objectId,
    );
    expect(afterShape.width, 3.0);
    expect(afterShape.color.toARGB32(), 0xFF345678);
    expect(afterShape.points, hasLength(2));
    expect(afterShape.points.last.dx, 11.0);

    final remoteOrder = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000000504',
      actorId: 'other-device',
      actorSeq: 4,
      logicalClock: remoteShape.logicalClock + 1,
      dependencies: [remoteShape.operationId],
      documentId: notebook.uid,
      pageId: pageId,
      objectId: remote.objectId,
      kind: OperationKind.objectReorder,
      payload: const {
        'properties': {'sortIndex': 1},
      },
    );
    fixture.accepted.add(remoteOrder.toJson());
    await fixture.runtime.engine.syncNow();
    expect(
      await fixture.runtime.store.checkpoint('account:startup-account'),
      6,
    );
    final afterOrder = (await fixture.repository.getNotebook(notebook.uid))!;
    expect(afterOrder.pages.single.inkStrokes.last.id, remote.objectId);
    expect(afterOrder.pages.single.inkStrokes.last.width, 3.0);

    final competing = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000000505',
      actorId: 'other-device',
      actorSeq: 5,
      logicalClock: remoteOrder.logicalClock + 1,
      dependencies: [remoteOrder.operationId],
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
      7,
    );
    expect(
      await fixture.runtime.store.operation(competing.operationId),
      isNotNull,
    );
    final afterConflict = (await fixture.repository.getNotebook(notebook.uid))!;
    expect(
      afterConflict.pages.single.inkStrokes
          .singleWhere((stroke) => stroke.id == remote.objectId)
          .width,
      4.0,
    );
    expect(
      (await fixture.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId, localSet.operationId],
    );
  });
  test('offline Quill attributes use deterministic precedence', () async {
    final fixture = _Fixture(NativeDatabase.memory());
    addTearDown(fixture.close);
    expect(
      await fixture.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final notebook = await fixture.repository.createNotebook();
    await fixture.runtime.engine.syncNow();
    final pageId = notebook.pages.single.id;
    final actor = fixture.runtime.engine.actorIdForDocument(notebook.uid);
    const textId = 'quill-offline-format';
    const atomId = '00000000-0000-4000-8000-000000009901';
    await fixture.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      kind: OperationKind.objectCreate,
      pageId: pageId,
      objectId: textId,
      payload: const {
        'value': {
          'objectType': 'text',
          'dx': 5.0,
          'dy': 6.0,
          'width': 160.0,
          'fontSize': 18.0,
          'rotation': 0.0,
          'colorValue': 0xFF224466,
          'sortIndex': 0,
        },
      },
      apply: fixture.runtime.projector.apply,
    );
    await fixture.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      kind: OperationKind.textInsert,
      pageId: pageId,
      objectId: textId,
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': atomId, 'text': 'Hello\n'},
        ],
      },
      apply: fixture.runtime.projector.apply,
    );
    await fixture.runtime.engine.syncNow();

    final local = await fixture.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      kind: OperationKind.textFormat,
      pageId: pageId,
      objectId: textId,
      payload: const {
        'atomIds': [atomId],
        'attributes': {'bold': true},
      },
      apply: fixture.runtime.projector.apply,
    );
    fixture.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009902',
      actorId: 'quill-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [fixture.accepted.last['operationId'] as String],
      documentId: notebook.uid,
      pageId: pageId,
      objectId: textId,
      kind: OperationKind.textFormat,
      payload: const {
        'atomIds': [atomId],
        'attributes': {'italic': true},
      },
    );
    fixture.accepted.add(remote.toJson());
    await fixture.runtime.engine.syncNow();
    final merged = (await fixture.repository.getNotebook(
      notebook.uid,
    ))!.pages.single.textBlocks.single;
    expect(merged.deltaJson, contains('"bold":true'));
    expect(merged.deltaJson, contains('"italic":true'));
    final cursor = await fixture.runtime.store.checkpoint(
      'account:startup-account',
    );
    expect(cursor, 5);

    final conflict = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009903',
      actorId: 'quill-peer',
      actorSeq: 2,
      logicalClock: remote.logicalClock + 1,
      dependencies: [remote.operationId],
      documentId: notebook.uid,
      pageId: pageId,
      objectId: textId,
      kind: OperationKind.textFormat,
      payload: const {
        'atomIds': [atomId],
        'attributes': {'bold': null},
      },
    );
    fixture.accepted.add(conflict.toJson());
    await fixture.runtime.engine.syncNow();
    expect(
      await fixture.runtime.store.checkpoint('account:startup-account'),
      cursor + 1,
    );
    expect(
      await fixture.runtime.store.operation(conflict.operationId),
      isNotNull,
    );
    final afterConflict = (await fixture.repository.getNotebook(
      notebook.uid,
    ))!.pages.single.textBlocks.single;
    expect(afterConflict.deltaJson, isNot(contains('"bold":true')));
    expect(afterConflict.deltaJson, contains('"italic":true'));
    expect(
      (await fixture.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId],
    );
  });

  test('remote metadata preserves offline ink; delete waits for ACK', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final page = note.pages.single.id;
    final local = await f.runtime.store.writeLocal(
      actorId: f.runtime.engine.actorIdForDocument(note.uid),
      documentId: note.uid,
      kind: OperationKind.strokeCreate,
      pageId: page,
      objectId: 'offline-ink',
      payload: const {
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
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final rename = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009911',
      actorId: 'metadata-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Remote title'},
      },
    );
    f.accepted.add(rename.toJson());
    await f.runtime.engine.syncNow();
    final bookmark = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009912',
      actorId: 'metadata-peer',
      actorSeq: 2,
      logicalClock: rename.logicalClock + 1,
      dependencies: [rename.operationId],
      documentId: note.uid,
      objectId: page,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'isBookmarked': true},
      },
    );
    f.accepted.add(bookmark.toJson());
    await f.runtime.engine.syncNow();
    final merged = (await f.repository.getNotebook(note.uid))!;
    expect(merged.title, 'Remote title');
    expect(merged.pages.single.isBookmarked, isTrue);
    expect(merged.pages.single.inkStrokes.single.id, local.objectId);
    final cursor = await f.runtime.store.checkpoint('account:startup-account');
    expect(cursor, 4);
    final deletion = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009913',
      actorId: 'metadata-peer',
      actorSeq: 3,
      logicalClock: bookmark.logicalClock + 1,
      dependencies: [bookmark.operationId],
      documentId: note.uid,
      kind: OperationKind.documentDelete,
      payload: const {},
    );
    f.accepted.add(deletion.toJson());
    await f.runtime.engine.syncNow();
    expect(await f.runtime.store.checkpoint('account:startup-account'), cursor);
    expect(await f.runtime.store.operation(deletion.operationId), isNull);
    final preserved = (await f.repository.getNotebook(note.uid))!;
    expect(preserved.pages.single.inkStrokes.single.id, local.objectId);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId],
    );
  });

  test('offline Quill insert commutes with format on existing atom', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final page = note.pages.single.id;
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    const textId = 'offline-quill-insert';
    const first = '00000000-0000-4000-8000-000000009951';
    const second = '00000000-0000-4000-8000-000000009952';
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: page,
      objectId: textId,
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {
          'objectType': 'text',
          'dx': 5.0,
          'dy': 6.0,
          'width': 160.0,
          'fontSize': 18.0,
          'rotation': 0.0,
          'colorValue': 0xFF224466,
          'sortIndex': 0,
        },
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: page,
      objectId: textId,
      kind: OperationKind.textInsert,
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': first, 'text': 'Hello\n'},
        ],
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: page,
      objectId: textId,
      kind: OperationKind.textInsert,
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': second, 'text': 'Offline '},
        ],
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009953',
      actorId: 'quill-insert-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      pageId: page,
      objectId: textId,
      kind: OperationKind.textFormat,
      payload: const {
        'atomIds': [first],
        'attributes': {'bold': true},
      },
    );
    f.accepted.add(remote.toJson());
    await f.runtime.engine.syncNow();
    final block = (await f.repository.getNotebook(
      note.uid,
    ))!.pages.single.textBlocks.single;
    expect(block.text, contains('Offline '));
    expect(block.text, contains('Hello'));
    expect(block.deltaJson, contains('"bold":true'));
    expect(await f.runtime.store.checkpoint('account:startup-account'), 5);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId],
    );
  });

  test('offline object deletion survives remote page creation', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    final pageId = note.pages.single.id;
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      kind: OperationKind.strokeCreate,
      pageId: pageId,
      objectId: 'offline-deleted-stroke',
      payload: const {
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
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final deletion = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      kind: OperationKind.objectDelete,
      pageId: pageId,
      objectId: 'offline-deleted-stroke',
      payload: const {},
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009994',
      actorId: 'page-creation-peer',
      actorSeq: 1,
      logicalClock: deletion.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: 'page-from-peer',
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Peer page', 'isBookmarked': false},
      },
    );
    f.accepted.add(remote.toJson());
    await f.runtime.engine.syncNow();

    final merged = (await f.repository.getNotebook(note.uid))!;
    expect(merged.pages, hasLength(2));
    expect(merged.pages.first.inkStrokes, isEmpty);
    expect(merged.pages.last.id, remote.objectId);
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [deletion.operationId],
    );
    await f.runtime.engine.syncNow();
    expect((await f.repository.getNotebook(note.uid))!.pages, hasLength(2));
  });

  test('offline page title and remote bookmark keep both edits', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final page = note.pages.single.id;
    final local = await f.runtime.store.writeLocal(
      actorId: f.runtime.engine.actorIdForDocument(note.uid),
      documentId: note.uid,
      kind: OperationKind.pageSet,
      objectId: page,
      payload: const {
        'properties': {'title': 'Offline page title'},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009961',
      actorId: 'page-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: page,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'isBookmarked': true},
      },
    );
    f.accepted.add(remote.toJson());
    await f.runtime.engine.syncNow();
    final merged = (await f.repository.getNotebook(note.uid))!;
    expect(merged.pages.single.title, 'Offline page title');
    expect(merged.pages.single.isBookmarked, isTrue);
    final cursor = await f.runtime.store.checkpoint('account:startup-account');
    expect(cursor, 3);

    final conflicting = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009962',
      actorId: 'page-peer',
      actorSeq: 2,
      logicalClock: remote.logicalClock + 1,
      dependencies: [remote.operationId],
      documentId: note.uid,
      objectId: page,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'title': 'Conflicting title'},
      },
    );
    f.accepted.add(conflicting.toJson());
    await f.runtime.engine.syncNow();
    expect(
      await f.runtime.store.checkpoint('account:startup-account'),
      cursor + 1,
    );
    expect(await f.runtime.store.operation(conflicting.operationId), isNotNull);
    final resolved = (await f.repository.getNotebook(note.uid))!;
    expect(resolved.pages.single.title, 'Conflicting title');
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId],
    );
  });

  test('offline Quill inserts survive replay without duplicates', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final page = note.pages.single.id;
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    const textId = 'quill-concurrent-inserts';
    const originalId = '00000000-0000-4000-8000-000000009971';
    const offlineId = '00000000-0000-4000-8000-000000009972';
    const remoteId = '00000000-0000-4000-8000-000000009973';
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: page,
      objectId: textId,
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {
          'objectType': 'text',
          'dx': 5.0,
          'dy': 6.0,
          'width': 160.0,
          'fontSize': 18.0,
          'rotation': 0.0,
          'colorValue': 0xFF224466,
          'sortIndex': 0,
        },
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: page,
      objectId: textId,
      kind: OperationKind.textInsert,
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': originalId, 'text': 'Base\n'},
        ],
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: page,
      objectId: textId,
      kind: OperationKind.textInsert,
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': offlineId, 'text': 'Offline '},
        ],
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009974',
      actorId: 'insert-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      pageId: page,
      objectId: textId,
      kind: OperationKind.textInsert,
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': remoteId, 'text': 'Remote '},
        ],
      },
    );
    f.accepted.add(remote.toJson());
    await f.runtime.engine.syncNow();
    final merged = (await f.repository.getNotebook(
      note.uid,
    ))!.pages.single.textBlocks.single;
    expect(merged.text, contains('Base'));
    expect(merged.text, contains('Offline '));
    expect(merged.text, contains('Remote '));
    final cursor = await f.runtime.store.checkpoint('account:startup-account');
    expect(cursor, 5);
    await f.runtime.engine.syncNow();
    final replayed = (await f.repository.getNotebook(
      note.uid,
    ))!.pages.single.textBlocks.single;
    expect(replayed.deltaJson, merged.deltaJson);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId],
    );
  });
  test('SQLite restart keeps offline ink and remote title', () async {
    final directory = await Directory.systemTemp.createTemp('nn-v2-offline-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(directory.path + '/notes.sqlite');
    final first = _Fixture(NativeDatabase(file));
    late String documentId;
    late String localOperationId;
    late List<Map<String, dynamic>> feed;
    try {
      expect(
        await first.runtime.startForCurrentAccount(isCurrent: () => true),
        isTrue,
      );
      final note = await first.repository.createNotebook();
      documentId = note.uid;
      await first.runtime.engine.syncNow();
      final pageId = note.pages.single.id;
      final local = await first.runtime.store.writeLocal(
        actorId: first.runtime.engine.actorIdForDocument(documentId),
        documentId: documentId,
        pageId: pageId,
        objectId: 'offline-restart-stroke',
        kind: OperationKind.strokeCreate,
        payload: const {
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
        },
        apply: first.runtime.projector.apply,
      );
      localOperationId = local.operationId;
      first.rejectPosts = true;
      final remote = OperationEnvelope(
        operationId: '00000000-0000-4000-8000-000000009981',
        actorId: 'restart-peer',
        actorSeq: 1,
        logicalClock: local.logicalClock + 1,
        dependencies: [first.accepted.last['operationId'] as String],
        documentId: documentId,
        kind: OperationKind.documentSet,
        payload: const {
          'properties': {'title': 'Peer title'},
        },
      );
      first.accepted.add(remote.toJson());
      await first.runtime.engine.syncNow();
      expect(
        await first.runtime.store.checkpoint('account:startup-account'),
        3,
      );
      feed = first.accepted
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } finally {
      await first.close();
    }

    final restarted = _Fixture(NativeDatabase(file));
    addTearDown(restarted.close);
    restarted.accepted.addAll(feed);
    restarted.rejectPosts = true;
    expect(
      await restarted.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    await restarted.runtime.engine.syncNow();
    final restored = (await restarted.repository.getNotebook(documentId))!;
    expect(restored.title, 'Peer title');
    expect(restored.pages.single.inkStrokes, hasLength(1));
    expect(
      restored.pages.single.inkStrokes.single.id,
      'offline-restart-stroke',
    );
    expect(
      await restarted.runtime.store.checkpoint('account:startup-account'),
      3,
    );
    expect(
      (await restarted.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [localOperationId],
    );
    await restarted.runtime.engine.syncNow();
    final again = (await restarted.repository.getNotebook(documentId))!;
    expect(again.title, 'Peer title');
    expect(again.pages.single.inkStrokes, hasLength(1));
  });

  test('offline LWW title preserves three queued edits', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    final pageId = note.pages.single.id;
    final title = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline title'},
      },
      apply: f.runtime.projector.apply,
    );
    final bookmark = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      kind: OperationKind.pageSet,
      objectId: pageId,
      payload: const {
        'properties': {'isBookmarked': true},
      },
      apply: f.runtime.projector.apply,
    );
    final ink = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: pageId,
      objectId: 'offline-three-way-ink',
      kind: OperationKind.strokeCreate,
      payload: const {
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
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final folder = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009982',
      actorId: 'folder-peer',
      actorSeq: 1,
      logicalClock: ink.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'folder': 'Remote folder'},
      },
    );
    f.accepted.add(folder.toJson());
    await f.runtime.engine.syncNow();
    final merged = (await f.repository.getNotebook(note.uid))!;
    expect(merged.title, 'Offline title');
    expect(merged.folder, 'Remote folder');
    expect(merged.pages.single.isBookmarked, isTrue);
    expect(merged.pages.single.inkStrokes.single.id, 'offline-three-way-ink');
    expect(await f.runtime.store.checkpoint('account:startup-account'), 3);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [title.operationId, bookmark.operationId, ink.operationId],
    );

    final conflicting = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009983',
      actorId: 'folder-peer',
      actorSeq: 2,
      logicalClock: folder.logicalClock + 1,
      dependencies: [folder.operationId],
      documentId: note.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Remote conflict'},
      },
    );
    f.accepted.add(conflicting.toJson());
    await f.runtime.engine.syncNow();
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect((await f.repository.getNotebook(note.uid))!.title, 'Remote conflict');
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [title.operationId, bookmark.operationId, ink.operationId],
    );
  });
  test('offline Quill insert and remote text geometry merge', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final pageId = note.pages.single.id;
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    const objectId = 'offline-text-geometry';
    const firstAtom = '00000000-0000-4000-8000-000000009991';
    const offlineAtom = '00000000-0000-4000-8000-000000009992';
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: pageId,
      objectId: objectId,
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {
          'objectType': 'text',
          'dx': 5.0,
          'dy': 6.0,
          'width': 160.0,
          'fontSize': 18.0,
          'rotation': 0.0,
          'colorValue': 0xFF224466,
          'sortIndex': 0,
        },
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: pageId,
      objectId: objectId,
      kind: OperationKind.textInsert,
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': firstAtom, 'text': 'Base\n'},
        ],
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: pageId,
      objectId: objectId,
      kind: OperationKind.textInsert,
      payload: const {
        'afterAtomId': null,
        'atoms': [
          {'id': offlineAtom, 'text': 'Offline '},
        ],
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009993',
      actorId: 'geometry-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      pageId: pageId,
      objectId: objectId,
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'width': 240.0, 'dx': 24.0},
      },
    );
    f.accepted.add(remote.toJson());
    await f.runtime.engine.syncNow();
    final block = (await f.repository.getNotebook(
      note.uid,
    ))!.pages.single.textBlocks.single;
    expect(block.width, 240.0);
    expect(block.position.dx, 24.0);
    expect(block.text, contains('Base'));
    expect(block.text, contains('Offline '));
    expect(await f.runtime.store.checkpoint('account:startup-account'), 5);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId],
    );
  });

  test('remote stroke updates replay past offline page bookmark', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final pageId = note.pages.single.id;
    final local = await f.runtime.store.writeLocal(
      actorId: f.runtime.engine.actorIdForDocument(note.uid),
      documentId: note.uid,
      objectId: pageId,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'isBookmarked': true},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final create = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009a01',
      actorId: 'stroke-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      pageId: pageId,
      objectId: 'peer-offline-stroke',
      kind: OperationKind.strokeCreate,
      payload: const {
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
      },
    );
    f.accepted.add(create.toJson());
    await f.runtime.engine.syncNow();
    var saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.pages.single.isBookmarked, isTrue);
    expect(saved.pages.single.inkStrokes.single.id, 'peer-offline-stroke');
    expect(await f.runtime.store.checkpoint('account:startup-account'), 3);
    final update = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009a02',
      actorId: 'stroke-peer',
      actorSeq: 2,
      logicalClock: create.logicalClock + 1,
      dependencies: [create.operationId],
      documentId: note.uid,
      pageId: pageId,
      objectId: create.objectId,
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'width': 4.0},
      },
    );
    f.accepted.add(update.toJson());
    await f.runtime.engine.syncNow();
    saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.pages.single.isBookmarked, isTrue);
    expect(saved.pages.single.inkStrokes.single.width, 4.0);
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId],
    );
  });

  test('remote stroke merges with two offline metadata edits', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final pageId = note.pages.single.id;
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: pageId,
      objectId: 'shared-stroke',
      kind: OperationKind.strokeCreate,
      payload: const {
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
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final localTitle = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline title'},
      },
      apply: f.runtime.projector.apply,
    );
    final localBookmark = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: pageId,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'isBookmarked': true},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-000000009a03',
      actorId: 'geometry-peer',
      actorSeq: 1,
      logicalClock: localBookmark.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      pageId: pageId,
      objectId: 'shared-stroke',
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'width': 5.0},
      },
    );
    f.accepted.add(remote.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.title, 'Offline title');
    expect(saved.pages.single.isBookmarked, isTrue);
    expect(saved.pages.single.inkStrokes.single.width, 5.0);
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [localTitle.operationId, localBookmark.operationId],
    );
  });

  test('offline metadata survives remote page create', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    final localTitle = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline title'},
      },
      apply: f.runtime.projector.apply,
    );
    final bookmark = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: note.pages.single.id,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'isBookmarked': true},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final created = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000a001',
      actorId: 'page-peer',
      actorSeq: 1,
      logicalClock: bookmark.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: 'remote-new-page',
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Remote page', 'isBookmarked': false},
      },
    );
    f.accepted.add(created.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.title, 'Offline title');
    expect(saved.pages, hasLength(2));
    expect(saved.pages.first.isBookmarked, isTrue);
    expect(saved.pages.last.id, 'remote-new-page');
    expect(saved.pages.last.title, 'Remote page');
    expect(await f.runtime.store.checkpoint('account:startup-account'), 3);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((entry) => entry.operationId),
      [localTitle.operationId, bookmark.operationId],
    );
  });

  test('remote new page preserves pending ink on another page', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: f.runtime.engine.actorIdForDocument(note.uid),
      documentId: note.uid,
      pageId: note.pages.single.id,
      objectId: 'offline-page-create-ink',
      kind: OperationKind.strokeCreate,
      payload: const {
        'value': {
          'objectType': 'stroke',
          'colorValue': 0xFF224466,
          'width': 2.0,
          'toolIndex': 0,
          'sortIndex': 0,
          'points': [
            [1.0, 2.0, 0.5],
          ],
        },
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final created = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000a002',
      actorId: 'page-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: 'remote-second-page',
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Second', 'isBookmarked': false},
      },
    );
    f.accepted.add(created.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.pages, hasLength(2));
    expect(saved.pages.first.inkStrokes.single.id, 'offline-page-create-ink');
    expect(saved.pages.last.id, 'remote-second-page');
    expect(await f.runtime.store.checkpoint('account:startup-account'), 3);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((entry) => entry.operationId),
      [local.operationId],
    );
  });

  test('remote page remains unique after SQLite restart', () async {
    final dir = await Directory.systemTemp.createTemp('nn-page-restart-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(dir.path + '/notes.sqlite');
    final first = _Fixture(NativeDatabase(file));
    late String documentId;
    late String localOperationId;
    late List<Map<String, dynamic>> feed;
    try {
      expect(
        await first.runtime.startForCurrentAccount(isCurrent: () => true),
        isTrue,
      );
      final note = await first.repository.createNotebook();
      documentId = note.uid;
      await first.runtime.engine.syncNow();
      final local = await first.runtime.store.writeLocal(
        actorId: first.runtime.engine.actorIdForDocument(note.uid),
        documentId: note.uid,
        objectId: note.pages.single.id,
        kind: OperationKind.pageSet,
        payload: const {
          'properties': {'isBookmarked': true},
        },
        apply: first.runtime.projector.apply,
      );
      localOperationId = local.operationId;
      first.rejectPosts = true;
      final created = OperationEnvelope(
        operationId: '00000000-0000-4000-8000-00000000a003',
        actorId: 'page-restart-peer',
        actorSeq: 1,
        logicalClock: local.logicalClock + 1,
        dependencies: [first.accepted.last['operationId'] as String],
        documentId: documentId,
        objectId: 'remote-restart-page',
        kind: OperationKind.pageCreate,
        payload: const {
          'value': {'title': 'Persisted peer page', 'isBookmarked': false},
        },
      );
      first.accepted.add(created.toJson());
      await first.runtime.engine.syncNow();
      expect(
        await first.runtime.store.checkpoint('account:startup-account'),
        3,
      );
      feed = first.accepted
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } finally {
      await first.close();
    }
    final restarted = _Fixture(NativeDatabase(file));
    addTearDown(restarted.close);
    restarted.accepted.addAll(feed);
    restarted.rejectPosts = true;
    expect(
      await restarted.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    await restarted.runtime.engine.syncNow();
    final note = (await restarted.repository.getNotebook(documentId))!;
    expect(note.pages, hasLength(2));
    expect(note.pages.first.isBookmarked, isTrue);
    expect(note.pages.last.id, 'remote-restart-page');
    expect(
      await restarted.runtime.store.checkpoint('account:startup-account'),
      3,
    );
    expect(
      (await restarted.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [localOperationId],
    );
    await restarted.runtime.engine.syncNow();
    expect(
      (await restarted.repository.getNotebook(documentId))!.pages,
      hasLength(2),
    );
  });

  test('conflicting remote page identity does not advance cursor', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: f.runtime.engine.actorIdForDocument(note.uid),
      documentId: note.uid,
      objectId: note.pages.single.id,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'isBookmarked': true},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final collision = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000a004',
      actorId: 'collision-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: note.pages.single.id,
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Conflicting page', 'isBookmarked': false},
      },
    );
    f.accepted.add(collision.toJson());
    await f.runtime.engine.syncNow();
    final current = (await f.repository.getNotebook(note.uid))!;
    expect(current.pages, hasLength(1));
    expect(current.pages.single.isBookmarked, isTrue);
    expect(await f.runtime.store.checkpoint('account:startup-account'), 2);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((operation) => operation.operationId),
      [local.operationId],
    );
  });

  test('remote delete preserves unrelated metadata', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    const removedPageId = 'peer-removed-page';
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: removedPageId,
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Temporary', 'isBookmarked': false},
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final localTitle = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline document'},
      },
      apply: f.runtime.projector.apply,
    );
    final localBookmark = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: note.pages.single.id,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'isBookmarked': true},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remove = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000b011',
      actorId: 'delete-peer',
      actorSeq: 1,
      logicalClock: localBookmark.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: removedPageId,
      kind: OperationKind.pageDelete,
      payload: const {},
    );
    f.accepted.add(remove.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.title, 'Offline document');
    expect(saved.pages, hasLength(1));
    expect(saved.pages.single.id, note.pages.single.id);
    expect(saved.pages.single.isBookmarked, isTrue);
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [localTitle.operationId, localBookmark.operationId],
    );
  });

  test('remote delete preserves pending ink', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    const removedPageId = 'second-offline-page';
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: removedPageId,
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Temporary', 'isBookmarked': false},
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final ink = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      pageId: note.pages.single.id,
      objectId: 'preserved-offline-ink',
      kind: OperationKind.strokeCreate,
      payload: const {
        'value': {
          'objectType': 'stroke',
          'colorValue': 0xFF224466,
          'width': 2.0,
          'toolIndex': 0,
          'sortIndex': 0,
          'points': [
            [1.0, 2.0, 0.5],
          ],
        },
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remove = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000b012',
      actorId: 'delete-peer',
      actorSeq: 1,
      logicalClock: ink.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: removedPageId,
      kind: OperationKind.pageDelete,
      payload: const {},
    );
    f.accepted.add(remove.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.pages, hasLength(1));
    expect(saved.pages.single.inkStrokes.single.id, 'preserved-offline-ink');
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [ink.operationId],
    );
  });

  test('local delete merges remote page title', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    const removedPageId = 'deleted-locally-page';
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: removedPageId,
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Temporary', 'isBookmarked': false},
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final deleted = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: removedPageId,
      kind: OperationKind.pageDelete,
      payload: const {},
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remoteTitle = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000b013',
      actorId: 'title-peer',
      actorSeq: 1,
      logicalClock: deleted.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: note.pages.single.id,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'title': 'Surviving page'},
      },
    );
    f.accepted.add(remoteTitle.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.pages, hasLength(1));
    expect(saved.pages.single.title, 'Surviving page');
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [deleted.operationId],
    );
  });

  test('same-page delete holds pending page edits', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final note = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final actor = f.runtime.engine.actorIdForDocument(note.uid);
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: 'kept-after-conflict',
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Second', 'isBookmarked': false},
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: note.uid,
      objectId: note.pages.single.id,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'title': 'Still local'},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remove = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000b014',
      actorId: 'delete-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: note.uid,
      objectId: note.pages.single.id,
      kind: OperationKind.pageDelete,
      payload: const {},
    );
    f.accepted.add(remove.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(note.uid))!;
    expect(saved.pages, hasLength(2));
    expect(saved.pages.first.title, 'Still local');
    expect(await f.runtime.store.checkpoint('account:startup-account'), 3);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [local.operationId],
    );
  });

  test('remote ink move preserves offline bookmark on source page', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final notebook = await f.repository.createNotebook();
    final source = notebook.pages.single.id;
    final actor = f.runtime.engine.actorIdForDocument(notebook.uid);
    await f.runtime.engine.syncNow();
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      objectId: 'move-peer-page',
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Peer destination', 'isBookmarked': false},
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      pageId: source,
      objectId: 'move-peer-stroke',
      kind: OperationKind.strokeCreate,
      payload: const {
        'value': {
          'objectType': 'stroke',
          'colorValue': 0xFF224466,
          'width': 2.0,
          'toolIndex': 0,
          'sortIndex': 0,
          'points': [
            [1.0, 2.0, 0.5],
          ],
        },
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      objectId: source,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'isBookmarked': true},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final expectedCursor = f.accepted.length + 1;
    final remoteMove = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000c001',
      actorId: 'move-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: notebook.uid,
      pageId: source,
      objectId: 'move-peer-stroke',
      kind: OperationKind.objectMove,
      payload: const {'toPageId': 'move-peer-page', 'sortIndex': 0},
    );
    f.accepted.add(remoteMove.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(notebook.uid))!;
    expect(saved.pages, hasLength(2));
    expect(saved.pages.first.isBookmarked, isTrue);
    expect(saved.pages.first.inkStrokes, isEmpty);
    expect(saved.pages.last.inkStrokes.single.id, 'move-peer-stroke');
    expect(
      await f.runtime.store.checkpoint('account:startup-account'),
      expectedCursor,
    );
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [local.operationId],
    );
  });

  test('pending ink move allows independent remote page title', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final notebook = await f.repository.createNotebook();
    final source = notebook.pages.single.id;
    final actor = f.runtime.engine.actorIdForDocument(notebook.uid);
    await f.runtime.engine.syncNow();
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      objectId: 'local-move-target',
      kind: OperationKind.pageCreate,
      payload: const {
        'value': {'title': 'Move target', 'isBookmarked': false},
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      pageId: source,
      objectId: 'local-move-stroke',
      kind: OperationKind.strokeCreate,
      payload: const {
        'value': {
          'objectType': 'stroke',
          'colorValue': 0xFF224466,
          'width': 2.0,
          'toolIndex': 0,
          'sortIndex': 0,
          'points': [
            [1.0, 2.0, 0.5],
          ],
        },
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      pageId: source,
      objectId: 'local-move-stroke',
      kind: OperationKind.objectMove,
      payload: const {'toPageId': 'local-move-target', 'sortIndex': 0},
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final expectedCursor = f.accepted.length + 1;
    final title = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000c002',
      actorId: 'metadata-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: notebook.uid,
      objectId: source,
      kind: OperationKind.pageSet,
      payload: const {
        'properties': {'title': 'Remote title'},
      },
    );
    f.accepted.add(title.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(notebook.uid))!;
    expect(saved.pages, hasLength(2));
    expect(saved.pages.first.title, 'Remote title');
    expect(saved.pages.first.inkStrokes, isEmpty);
    expect(saved.pages.last.inkStrokes.single.id, 'local-move-stroke');
    expect(
      await f.runtime.store.checkpoint('account:startup-account'),
      expectedCursor,
    );
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [local.operationId],
    );
  });

  test('offline notebook title survives older remote rank', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final notebook = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: f.runtime.engine.actorIdForDocument(notebook.uid),
      documentId: notebook.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Offline wins'},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final older = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000d201',
      actorId: 'title-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock - 1,
      dependencies: [f.accepted.first['operationId'] as String],
      documentId: notebook.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Older remote'},
      },
    );
    f.accepted.add(older.toJson());
    await f.runtime.engine.syncNow();
    expect(
      (await f.repository.getNotebook(notebook.uid))!.title,
      'Offline wins',
    );
    expect(await f.runtime.store.checkpoint('account:startup-account'), 3);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [local.operationId],
    );

    final newer = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000d202',
      actorId: 'title-peer',
      actorSeq: 2,
      logicalClock: local.logicalClock + 1,
      dependencies: [older.operationId],
      documentId: notebook.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Newer remote'},
      },
    );
    f.accepted.add(newer.toJson());
    await f.runtime.engine.syncNow();
    expect(
      (await f.repository.getNotebook(notebook.uid))!.title,
      'Newer remote',
    );
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [local.operationId],
    );
  });

  test('offline stroke width and remote width converge by rank', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final notebook = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final page = notebook.pages.single.id;
    final actor = f.runtime.engine.actorIdForDocument(notebook.uid);
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      pageId: page,
      objectId: 'ranked-ink',
      kind: OperationKind.strokeCreate,
      payload: const {
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
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      pageId: page,
      objectId: 'ranked-ink',
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'width': 3.0},
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000d203',
      actorId: 'stroke-width-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: notebook.uid,
      pageId: page,
      objectId: 'ranked-ink',
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'width': 5.0},
      },
    );
    f.accepted.add(remote.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(notebook.uid))!;
    expect(saved.pages.single.inkStrokes.single.width, 5.0);
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [local.operationId],
    );
  });

  test('concurrent ink point changes keep one ranked geometry', () async {
    final f = _Fixture(NativeDatabase.memory());
    addTearDown(f.close);
    expect(
      await f.runtime.startForCurrentAccount(isCurrent: () => true),
      isTrue,
    );
    final notebook = await f.repository.createNotebook();
    await f.runtime.engine.syncNow();
    final page = notebook.pages.single.id;
    final actor = f.runtime.engine.actorIdForDocument(notebook.uid);
    await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      pageId: page,
      objectId: 'point-register-stroke',
      kind: OperationKind.strokeCreate,
      payload: const {
        'value': {
          'objectType': 'stroke',
          'colorValue': 0xFF223344,
          'width': 2.0,
          'toolIndex': 0,
          'sortIndex': 0,
          'points': [
            [1.0, 2.0, 0.5],
          ],
        },
      },
      apply: f.runtime.projector.apply,
    );
    await f.runtime.engine.syncNow();
    final local = await f.runtime.store.writeLocal(
      actorId: actor,
      documentId: notebook.uid,
      pageId: page,
      objectId: 'point-register-stroke',
      kind: OperationKind.objectTransform,
      payload: const {
        'properties': {
          'points': [
            [10.0, 20.0, 0.5],
          ],
        },
      },
      apply: f.runtime.projector.apply,
    );
    f.rejectPosts = true;
    final remote = OperationEnvelope(
      operationId: '00000000-0000-4000-8000-00000000d204',
      actorId: 'point-peer',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      dependencies: [f.accepted.last['operationId'] as String],
      documentId: notebook.uid,
      pageId: page,
      objectId: 'point-register-stroke',
      kind: OperationKind.objectTransform,
      payload: const {
        'properties': {
          'points': [
            [30.0, 40.0, 0.8],
            [31.0, 41.0, 0.9],
          ],
        },
      },
    );
    f.accepted.add(remote.toJson());
    await f.runtime.engine.syncNow();
    final saved = (await f.repository.getNotebook(notebook.uid))!;
    final points = saved.pages.single.inkStrokes.single.points;
    expect(points, hasLength(2));
    expect(points.first.dx, 30.0);
    expect(points.last.dy, 41.0);
    expect(await f.runtime.store.checkpoint('account:startup-account'), 4);
    expect(
      (await f.runtime.store.pending(
        includeDeferred: true,
      )).map((op) => op.operationId),
      [local.operationId],
    );
  });
}
