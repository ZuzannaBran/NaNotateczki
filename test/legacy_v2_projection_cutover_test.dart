import 'dart:convert';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/active_storage_namespace.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/editor_v2_account_runtime.dart';
import 'package:program/data/sync/legacy_sync_archive.dart';
import 'package:program/data/sync/legacy_v2_projection_cutover.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/text_block.dart';
import 'package:uuid/uuid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NotesDatabase database;
  late NotebookRepository repository;
  late Map<String, dynamic> local;
  late Map<String, dynamic> remote;
  late Map<String, dynamic> state;
  Map<String, dynamic>? localLibrary;
  Map<String, dynamic>? baseLibrary;
  Map<String, dynamic>? remoteLibrary;
  late ApiClient api;
  late LegacyV2ProjectionCutover cutover;
  var available = true;
  var requests = 0;
  var current = true;
  const receipt = LegacyCutoverReceipt(5, 90);

  setUp(() async {
    database = NotesDatabase(NativeDatabase.memory());
    repository = NotebookRepository(database);
    await repository.createNotebook(title: 'Saved v1');
    final notebook = (await repository.fetchNotebooks()).single;
    local = LegacySyncArchive.encodeCutoverNotebook(notebook);
    remote = {...local};
    state = {
      'version': 1,
      'cursor': 4,
      'revisions': {notebook.uid: 2},
      'pending': <String>[],
    };
    localLibrary = baseLibrary = remoteLibrary = null;
    textStorageReadOverride = (key) async {
      if (key.startsWith('server_sync_state_')) return jsonEncode(state);
      if (key.startsWith('account_settings_cursor_') && baseLibrary != null) {
        return jsonEncode({
          'settings': {
            'libraryState': {'revision': 1, 'value': baseLibrary},
          },
        });
      }
      if (key == 'library_folders.json' && localLibrary != null) {
        return jsonEncode(localLibrary);
      }
      return null;
    };
    current = available = true;
    requests = 0;
    api = ApiClient(
      baseUri: Uri.parse('https://api.example.test'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v2/activation/legacy-library') {
          return http.Response(jsonEncode({'library': remoteLibrary}), 200);
        }
        expect(request.url.path, '/v2/activation/legacy-source');
        expect(request.url.queryParameters, {
          'uid': notebook.uid,
          'revision': '2',
        });
        requests++;
        if (!available) {
          return http.Response('Unavailable', 503);
        }
        return http.Response(
          jsonEncode({'revision': 2, 'notebook': remote}),
          200,
        );
      }),
    )..setAccessToken('test-token');
    cutover = LegacyV2ProjectionCutover(
      repository: repository,
      apiClient: api,
      accountId: 'account-1',
      isCurrent: () => current,
    );
  });

  tearDown(() async {
    textStorageReadOverride = null;
    ActiveStorageNamespace.activate(StorageNamespace.local());
    api.close();
    await database.close();
  });

  test('retired outbox blocks v2 even without its deleted notebook', () async {
    state['pending'] = ['deleted-locally'];
    expect((await LegacySyncArchive.readCutoverState('account-1')).pending, {
      'deleted-locally',
    });
    await expectLater(
      LegacySyncArchive.requireEmptyLegacyOutbox('account-1'),
      throwsStateError,
    );
    state['pending'] = <String>[];
    await LegacySyncArchive.requireEmptyLegacyOutbox('account-1');
    state['pending'] = [42];
    await expectLater(
      LegacySyncArchive.requireEmptyLegacyOutbox('account-1'),
      throwsFormatException,
    );
  });

  test(
    'legacy library receipt queues and replays offline changes once',
    () async {
      ActiveStorageNamespace.activate(StorageNamespace.account('account-1'));
      baseLibrary = {'folders': <String>[]};
      localLibrary = {
        'folders': ['Offline folder'],
      };
      remoteLibrary = {
        'folders': ['Remote folder'],
      };
      await cutover.prepare(receipt);
      final runtime = EditorV2AccountRuntime(
        repository: repository,
        apiClient: api,
        accountId: 'account-1',
        actorId: 'migration-test',
        enableRealtime: false,
      );
      addTearDown(runtime.dispose);
      final converted = OperationEnvelope.fromJson({
        'schemaVersion': 1,
        'operationId': const Uuid().v4(),
        'actorId': 'v1-cutover:library',
        'actorSeq': 1,
        'logicalClock': 1,
        'documentId': OperationEnvelope.libraryDocumentId,
        'objectId': const Uuid().v4(),
        'type': 'folder.create',
        'dependencies': <String>[],
        'payload': {
          'value': {'name': 'Remote folder', 'parentId': null},
        },
      });
      await runtime.store.applyRemote(
        converted,
        serverSequence: 90,
        checkpointScope: 'account:account-1',
        apply: () => runtime.libraryOperations.apply(converted),
      );
      Future<void> replay() => cutover.replayPending(
        writer: runtime.writer,
        store: runtime.store,
        library: runtime.libraryOperations,
      );
      await replay();
      final queued = (await runtime.store.pending()).single;
      expect(queued.kind, OperationKind.folderCreate);
      expect(
        (await runtime.libraryOperations.snapshot()).folderIdsByPath.keys,
        unorderedEquals(['Remote folder', 'Offline folder']),
      );
      await cutover.prepare(receipt);
      await replay();
      expect(
        (await runtime.store.pending()).single.operationId,
        queued.operationId,
      );
      expect(await cutover.conflicts(), isEmpty);
    },
  );

  test('archives original rows atomically and resumes without replacing v2', () async {
    available = false;
    await expectLater(cutover.prepare(receipt), throwsA(isA<ApiException>()));
    expect((await repository.fetchNotebooks()).single.title, 'Saved v1');
    final absent = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE name = 'legacy_v1_notebook_rows'",
        )
        .get();
    expect(absent, isEmpty);

    available = true;
    await cutover.prepare(receipt);
    expect(await repository.fetchNotebooks(), isEmpty);
    final archived = await database
        .customSelect('SELECT uid, title FROM legacy_v1_notebook_rows')
        .getSingle();
    expect(archived.data, {'uid': local['uid'], 'title': 'Saved v1'});
    final projector = EditorSqliteProjector(database);
    final store = OperationStore(
      database,
      checkpointScope: 'account:account-1',
    );
    String? previous;
    var seq = 0;
    Future<void> replay(
      OperationKind kind, {
      String? obj,
      String? page,
      Map<String, dynamic> payload = const {},
      String? document,
    }) async {
      seq++;
      final op = OperationEnvelope.fromJson({
        'schemaVersion': 1,
        'operationId': const Uuid().v4(),
        'actorId': 'v1-cutover:test-device',
        'actorSeq': seq,
        'documentId': document ?? local['uid'],
        'type': kind.wireName,
        'payload': payload,
        'dependencies': [?previous],
        'logicalClock': seq,
        'objectId': ?obj,
        'pageId': ?page,
      });
      previous = op.operationId;
      await store.applyRemote(
        op,
        checkpointScope: 'account:account-1',
        serverSequence: 90 - 4 + seq,
        apply: () => projector.apply(op),
      );
    }

    await replay(
      OperationKind.documentCreate,
      payload: {
        'value': {
          'title': 'Migrated v2',
          'folder': 'Notes',
          'kindIndex': 0,
          'createdAt': local['createdAt'],
          'updatedAt': local['updatedAt'],
        },
      },
    );
    await replay(
      OperationKind.pageCreate,
      obj: 'live-page',
      payload: {
        'value': {'title': 'Live', 'isBookmarked': true},
      },
    );
    await replay(
      OperationKind.objectDelete,
      obj: 'deleted-ink',
      page: 'old-page',
    );
    await replay(OperationKind.pageDelete, obj: 'old-page');
    expect(await store.checkpoint('account:account-1'), 90);
    expect(
      await store.isTombstoned(local['uid'] as String, 'page', 'old-page'),
      isTrue,
    );
    expect(
      await store.wasObjectDeleted(
        documentId: local['uid'] as String,
        objectId: 'deleted-ink',
      ),
      isTrue,
    );
    // The same durable receipt is harmless after startup/replay, even offline.
    available = false;
    await cutover.prepare(receipt);
    expect(requests, 2);
    final migrated = (await repository.fetchNotebooks()).single;
    expect(migrated.title, 'Migrated v2');
    expect(
      migrated.updatedAt.toUtc(),
      DateTime.parse(local['updatedAt'] as String),
    );
    await expectLater(
      cutover.prepare(const LegacyCutoverReceipt(6, 90)),
      throwsStateError,
    );
  });

  test(
    'converts an offline edit exactly once without overwriting remote fields',
    () async {
      final uid = local['uid'] as String;
      state['pending'] = [uid];
      remote['title'] = 'Accepted v1 title';
      await cutover.prepare(receipt);
      final runtime = EditorV2AccountRuntime(
        repository: repository,
        apiClient: api,
        accountId: 'account-1',
        actorId: 'migration-test',
        enableRealtime: false,
      );
      addTearDown(runtime.dispose);
      final remoteNotebook = repository.decodeBackupStrict([remote]).single;
      final create = OperationEnvelope.fromJson({
        'schemaVersion': 1,
        'operationId': const Uuid().v4(),
        'actorId': 'migration-source',
        'actorSeq': 1,
        'logicalClock': 1,
        'documentId': uid,
        'type': 'document.create',
        'dependencies': <String>[],
        'payload': {
          'value': {
            'title': remote['title'],
            'folder': 'Remote folder',
            'kindIndex': 0,
            'createdAt': local['createdAt'],
          },
        },
      });
      final page = OperationEnvelope.fromJson({
        'schemaVersion': 1,
        'operationId': const Uuid().v4(),
        'actorId': create.actorId,
        'actorSeq': 2,
        'logicalClock': 2,
        'documentId': uid,
        'type': 'page.create',
        'dependencies': [create.operationId],
        'objectId': remoteNotebook.pages.single.id,
        'payload': {
          'value': {
            'title': remoteNotebook.pages.single.title,
            'isBookmarked': false,
          },
        },
      });
      for (final op in [create, page]) {
        await runtime.store.applyRemote(
          op,
          serverSequence: 88 + op.actorSeq,
          checkpointScope: 'account:account-1',
          apply: () => runtime.projector.apply(op),
        );
      }
      await cutover.replayPending(writer: runtime.writer, store: runtime.store);
      final queued = (await runtime.store.pending()).single;
      expect(queued.kind, OperationKind.documentSet);
      expect((await repository.getNotebook(uid))!.title, 'Saved v1');
      expect((await repository.getNotebook(uid))!.folder, 'Remote folder');
      await cutover.prepare(receipt);
      await cutover.replayPending(writer: runtime.writer, store: runtime.store);
      expect(
        (await runtime.store.pending()).single.operationId,
        queued.operationId,
      );
    },
  );

  test('a remotely deleted UID is not revived by an offline edit', () async {
    final uid = local['uid'] as String;
    state['pending'] = [uid];
    remote['title'] = 'Accepted title before deletion';
    await cutover.prepare(receipt);
    final runtime = EditorV2AccountRuntime(
      repository: repository,
      apiClient: api,
      accountId: 'account-1',
      actorId: 'migration-test',
      enableRealtime: false,
    );
    addTearDown(runtime.dispose);
    final deletion = OperationEnvelope.fromJson({
      'schemaVersion': 1,
      'operationId': const Uuid().v4(),
      'actorId': 'server-deletion',
      'actorSeq': 1,
      'logicalClock': 1,
      'documentId': uid,
      'type': 'document.delete',
      'dependencies': <String>[],
      'payload': <String, dynamic>{},
    });
    await runtime.store.applyRemote(
      deletion,
      serverSequence: 90,
      checkpointScope: 'account:account-1',
      apply: () => runtime.projector.apply(deletion),
    );
    await cutover.replayPending(writer: runtime.writer, store: runtime.store);
    expect(await repository.getNotebook(uid), isNull);
    expect(await runtime.store.pending(), isEmpty);
    expect((await cutover.conflicts()).single.uid, uid);
    expect(await runtime.recoveryReport(), contains('Saved v1'));
    await runtime.restoreRecoveryCopies(isCurrent: () => true);
    await runtime.restoreRecoveryCopies(isCurrent: () => true);
    final recovered = (await repository.fetchNotebooks()).single;
    expect(recovered.uid, isNot(uid));
    expect(recovered.title, 'Saved v1 (Recovered)');
    expect(await repository.getNotebook(uid), isNull);
  });

  test(
    'new offline document preserves its UID and converts an inline Quill image',
    () async {
      final fresh = await repository.createNotebook(title: 'Offline document');
      final page = fresh.pages.single;
      const bytes =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
          'AAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg==';
      expect(
        await repository.saveNotebook(
          fresh.copyWith(
            pages: [
              page.copyWith(
                textBlocks: [
                  TextBlock(
                    id: 'legacy-text-image',
                    text: '\ufffc',
                    position: Offset.zero,
                    fontSize: 16,
                    color: const Color(0xff000000),
                    width: 100,
                    deltaJson: jsonEncode([
                      {
                        'insert': {'image': 'data:image/png;base64,$bytes'},
                      },
                      {'insert': '\n'},
                    ]),
                  ),
                ],
              ),
            ],
          ),
        ),
        isTrue,
      );
      state['pending'] = [fresh.uid];
      await cutover.prepare(receipt);
      final runtime = EditorV2AccountRuntime(
        repository: repository,
        apiClient: api,
        accountId: 'account-1',
        actorId: 'migration-test',
        enableRealtime: false,
      );
      addTearDown(runtime.dispose);
      await cutover.replayPending(writer: runtime.writer, store: runtime.store);
      final recovered = (await repository.getNotebook(fresh.uid))!;
      final delta = recovered.pages.single.textBlocks.single.deltaJson!;
      expect(delta, contains('asset:'));
      expect(delta, isNot(contains('data:image')));
      final queued = await runtime.store.pending();
      expect(queued.map((op) => op.kind), contains(OperationKind.assetAttach));
      expect(queued.every((op) => op.documentId == fresh.uid), isTrue);
    },
  );

  test('unsent deletion of an already absent UID is a durable no-op', () async {
    state['pending'] = ['removed-local'];
    await cutover.prepare(receipt);
    final runtime = EditorV2AccountRuntime(
      repository: repository,
      apiClient: api,
      accountId: 'account-1',
      actorId: 'migration-test',
      enableRealtime: false,
    );
    addTearDown(runtime.dispose);
    await cutover.replayPending(writer: runtime.writer, store: runtime.store);
    final row = await database
        .customSelect(
          "SELECT uid, local_json, state FROM legacy_v1_cutover_intents "
          "WHERE uid = 'removed-local'",
        )
        .getSingle();
    expect(row.readNullable<String>('local_json'), isNull);
    expect(row.read<String>('state'), 'converted');
    expect(await runtime.store.pending(), isEmpty);
  });

  test('tombstone for a never-present notebook survives replay', () async {
    final store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    final op = OperationEnvelope.fromJson({
      'schemaVersion': 1,
      'operationId': const Uuid().v4(),
      'actorId': 'historical-deletion',
      'actorSeq': 1,
      'documentId': 'deleted-legacy',
      'type': 'document.delete',
      'payload': <String, dynamic>{},
      'dependencies': <String>[],
      'logicalClock': 1,
    });
    await store.applyRemote(
      op,
      serverSequence: 1,
      apply: () => projector.apply(op),
    );
    expect(
      await store.isTombstoned('deleted-legacy', 'document', 'deleted-legacy'),
      isTrue,
    );
  });
}
