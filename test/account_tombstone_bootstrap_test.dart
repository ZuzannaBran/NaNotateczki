import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/live_web_sync_service.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

import 'support/native_test_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();

  setUp(() {
    textStorageReadOverride = (_) async => null;
    textStorageWriteOverride = (_, _) async {};
  });

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('bootstrap tombstone never retains stale original document', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final original = await repository.createNotebook();
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response(
            jsonEncode({
              'cursor': 1,
              'notebooks': [
                {
                  'uid': original.uid,
                  'revision': 2,
                  'deleted': true,
                  'notebook': null,
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"cursor":1,"changes":[]}', 200);
        }
        fail('Unexpected account synchronization request');
      }),
    )..setAccessToken('token');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-1';
    addTearDown(session.dispose);
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
      enableRealtime: false,
    );
    addTearDown(sync.dispose);

    await sync.start(InitialSyncPolicy.mergeSafely);

    expect(await repository.getNotebook(original.uid), isNull);
    final saved = await repository.fetchNotebooks();
    expect(saved, isEmpty);
    expect(sync.hasPendingChanges, isFalse);
  });
  test('pending edit restores tombstoned original after reconnect', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final original = await repository.createNotebook(title: 'Offline note');
    final edited = original.copyWith(title: 'Edited after deletion');
    await repository.saveNotebook(edited);
    final suffix = sha256
        .convert(utf8.encode('account-1'))
        .toString()
        .substring(0, 16);
    final stored = <String, String>{
      'server_sync_state_$suffix.json': jsonEncode({
        'version': 1,
        'cursor': 0,
        'revisions': {original.uid: 1},
        'pending': [original.uid],
      }),
    };
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    var restored = false;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response(
            jsonEncode({
              'cursor': 2,
              'notebooks': [
                {
                  'uid': original.uid,
                  'revision': 2,
                  'deleted': true,
                  'notebook': null,
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"cursor":2,"changes":[]}', 200);
        }
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['expectedRevision'], 2);
          expect(body['restoreDeleted'], isTrue);
          expect(body['notebook']['uid'], original.uid);
          restored = true;
          return http.Response('{"revision":3}', 200);
        }
        fail('Unexpected sync endpoint: ${request.url}');
      }),
    )..setAccessToken('token');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-1';
    addTearDown(session.dispose);
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
      enableRealtime: false,
    );
    addTearDown(sync.dispose);

    await sync.start(InitialSyncPolicy.mergeSafely);

    expect(restored, isTrue);
    expect(sync.hasPendingChanges, isFalse);
    final saved = await repository.fetchNotebooks();
    expect(saved, hasLength(1));
    expect(saved.single.uid, original.uid);
    expect(saved.single.title, 'Edited after deletion');
  });

  test('editing before the first online sync persists an offline outbox', (
  ) async {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 503)),
    )..setAccessToken('token');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-1';
    addTearDown(session.dispose);
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
      enableRealtime: false,
    );
    addTearDown(sync.dispose);
    sync.enqueue([NotebookRepositoryChange.full(notebook.uid)]);
    await sync.stop();

    final suffix = sha256
        .convert(utf8.encode('account-1'))
        .toString()
        .substring(0, 16);
    final state = jsonDecode(
      stored['server_sync_state_$suffix.json']!,
    ) as Map<String, dynamic>;
    expect(state['pending'], contains(notebook.uid));
    expect(state['version'], 1);
  });

}
