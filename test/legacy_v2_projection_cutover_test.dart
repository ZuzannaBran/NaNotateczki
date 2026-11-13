import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/legacy_v2_projection_cutover.dart';
import 'package:program/data/sync/live_web_sync_service.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:uuid/uuid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NotesDatabase database;
  late NotebookRepository repository;
  late Map<String, dynamic> local;
  late Map<String, dynamic> remote;
  late Map<String, dynamic> state;
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
    local = LiveWebSyncService.encodeCutoverNotebook(notebook);
    remote = {...local};
    state = {
      'version': 1,
      'cursor': 4,
      'revisions': {notebook.uid: 2},
      'pending': <String>[],
    };
    textStorageReadOverride = (key) async =>
        key.startsWith('server_sync_state_') ? jsonEncode(state) : null;
    current = available = true;
    requests = 0;
    api = ApiClient(
      baseUri: Uri.parse('https://api.example.test'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v2/activation/legacy-library') {
          return http.Response(jsonEncode({'library': null}), 200);
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
    api.close();
    await database.close();
  });

  test(
    'archives original rows atomically and resumes without replacing v2',
    () async {
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
    },
  );

  test(
    'unsent deletes and divergent local content block before archival',
    () async {
      state['pending'] = ['removed-local'];
      await expectLater(cutover.prepare(receipt), throwsStateError);
      expect(requests, 0);
      state['pending'] = <String>[];
      remote['title'] = 'Different acknowledged revision';
      await expectLater(cutover.prepare(receipt), throwsStateError);
      expect(requests, 1);
      expect((await repository.fetchNotebooks()).single.title, 'Saved v1');
      expect(
        await database
            .customSelect(
              "SELECT name FROM sqlite_master WHERE name = 'legacy_v1_notebook_rows'",
            )
            .get(),
        isEmpty,
      );
    },
  );

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
