import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_credential_store.dart';
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

  test('drains every full page of the server change feed', () async {
    var changesCalls = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/auth/login') {
          return _sessionResponse();
        }
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response(jsonEncode({'cursor': 0, 'notebooks': []}), 200);
        }
        if (request.url.path == '/v1/sync/changes') {
          changesCalls++;
          if (changesCalls == 1) {
            return http.Response(
              jsonEncode({
                'cursor': 500,
                'changes': [
                  for (var index = 1; index <= 500; index++)
                    {
                      'uid': 'deleted-$index',
                      'revision': 1,
                      'deleted': true,
                      'notebook': null,
                    },
                ],
              }),
              200,
            );
          }
          expect(request.url.queryParameters['after'], '500');
          return http.Response(jsonEncode({'cursor': 500, 'changes': []}), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final session = AccountSessionController(client);
    await session.login('test_user', 'a-secure-password');
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
    );
    addTearDown(sync.dispose);

    await sync.start(InitialSyncPolicy.downloadRemote);

    expect(changesCalls, 2);
  });

  test('resuming Web sync reconciles missed realtime notifications', () async {
    var changeRequests = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/auth/login') {
          return _sessionResponse();
        }
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response(jsonEncode({'cursor': 0, 'notebooks': []}), 200);
        }
        if (request.url.path == '/v1/sync/changes') {
          changeRequests++;
          return http.Response(jsonEncode({'cursor': 0, 'changes': []}), 200);
        }
        fail('Unexpected request');
      }),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final session = AccountSessionController(client);
    await session.login('test_user', 'a-secure-password');
    final sync = LiveWebSyncService(
      repository: NotebookRepository(database),
      apiClient: client,
      session: session,
    );
    addTearDown(sync.dispose);
    await sync.start(InitialSyncPolicy.downloadRemote);
    final initialRequests = changeRequests;

    sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await sync.syncNow();

    expect(changeRequests, greaterThan(initialRequests));
    await sync.stop();
    session.dispose();
    client.close();
  });

  test('does not skip concurrent remote events after its own push', () async {
    var changesCalls = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/auth/login') {
          return _sessionResponse();
        }
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response(
            jsonEncode({'cursor': 10, 'notebooks': []}),
            200,
          );
        }
        if (request.url.path == '/v1/sync/changes') {
          changesCalls++;
          expect(request.url.queryParameters['after'], '10');
          return http.Response(
            jsonEncode({'cursor': changesCalls == 1 ? 10 : 100, 'changes': []}),
            200,
          );
        }
        if (request.method == 'PUT' &&
            request.url.path.startsWith('/v1/sync/notebooks/')) {
          return http.Response(jsonEncode({'revision': 1, 'cursor': 100}), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    await repository.createNotebook();
    final session = AccountSessionController(client);
    await session.login('test_user', 'a-secure-password');
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
    );
    addTearDown(sync.dispose);

    await sync.start(InitialSyncPolicy.uploadLocal);
    await sync.syncNow();

    expect(changesCalls, 2);
  });

  test('stop and start do not carry account A outbox into account B', () async {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    var accountBDeletes = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/auth/login') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final isAccountA = body['username'] == 'account_a';
          return _sessionResponse(
            userId: isAccountA ? 'user-a' : 'user-b',
            username: body['username']! as String,
            accessToken: isAccountA ? 'access-a' : 'access-b',
          );
        }
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response(jsonEncode({'cursor': 0, 'notebooks': []}), 200);
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response(jsonEncode({'cursor': 0, 'changes': []}), 200);
        }
        if (request.method == 'PUT') {
          expect(request.headers['authorization'], 'Bearer access-a');
          return http.Response(jsonEncode({'revision': 1}), 200);
        }
        if (request.method == 'DELETE') {
          if (request.headers['authorization'] == 'Bearer access-b') {
            accountBDeletes++;
          }
          return http.Response(jsonEncode({'revision': 2}), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final sessionA = AccountSessionController(
      client,
      credentialStore: _MemoryAccountCredentialStore(),
    );
    final syncA = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: sessionA,
    );
    addTearDown(syncA.dispose);

    await sessionA.login('account_a', 'a-secure-password');
    await syncA.start(InitialSyncPolicy.uploadLocal);
    await repository.deleteNotebook(notebook.uid);
    syncA.enqueue([NotebookRepositoryChange.full(notebook.uid)]);
    await syncA.stop();

    sessionA.useLocalOnly();
    final sessionB = AccountSessionController(
      client,
      credentialStore: _MemoryAccountCredentialStore(),
    );
    final syncB = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: sessionB,
    );
    addTearDown(syncB.dispose);
    await sessionB.login('account_b', 'b-secure-password');
    await syncB.start(InitialSyncPolicy.downloadRemote);

    expect(accountBDeletes, 0);
    expect(
      stored.keys.where((key) => key.startsWith('server_sync_state_')),
      hasLength(2),
    );
  });
}

class _MemoryAccountCredentialStore implements AccountCredentialStore {
  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

http.Response _sessionResponse({
  String userId = 'user-1',
  String username = 'test_user',
  String accessToken = 'access',
}) {
  return http.Response(
    jsonEncode({
      'accessToken': accessToken,
      'refreshToken': 'refresh-token-with-at-least-forty-characters',
      'expiresIn': 600,
      'userId': userId,
      'username': username,
    }),
    200,
  );
}
