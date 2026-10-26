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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}

http.Response _sessionResponse() {
  return http.Response(
    jsonEncode({
      'accessToken': 'access',
      'refreshToken': 'refresh-token-with-at-least-forty-characters',
      'expiresIn': 600,
      'userId': 'user-1',
      'email': 'user@example.com',
    }),
    200,
  );
}
