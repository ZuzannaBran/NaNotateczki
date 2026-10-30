import 'dart:convert';

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
    await session.login('user@example.com', 'a-secure-password');
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
    );
    addTearDown(sync.dispose);

    await sync.start(InitialSyncPolicy.downloadRemote);

    expect(changesCalls, 2);
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
    await session.login('user@example.com', 'a-secure-password');
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
          final isAccountA = body['email'] == 'a@example.com';
          return _sessionResponse(
            userId: isAccountA ? 'user-a' : 'user-b',
            email: body['email']! as String,
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
    final session = AccountSessionController(client);
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
    );
    addTearDown(sync.dispose);

    await session.login('a@example.com', 'a-secure-password');
    await sync.start(InitialSyncPolicy.uploadLocal);
    await repository.deleteNotebook(notebook.uid);
    sync.enqueue([NotebookRepositoryChange.full(notebook.uid)]);
    await sync.stop();

    session.useLocalOnly();
    await session.login('b@example.com', 'b-secure-password');
    await sync.start(InitialSyncPolicy.downloadRemote);

    expect(accountBDeletes, 0);
    expect(
      stored.keys.where((key) => key.startsWith('server_sync_state_')),
      hasLength(2),
    );
  });
}

http.Response _sessionResponse({
  String userId = 'user-1',
  String email = 'user@example.com',
  String accessToken = 'access',
}) {
  return http.Response(
    jsonEncode({
      'accessToken': accessToken,
      'refreshToken': 'refresh-token-with-at-least-forty-characters',
      'expiresIn': 600,
      'userId': userId,
      'email': email,
    }),
    200,
  );
}
