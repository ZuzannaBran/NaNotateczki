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

  test('bootstrap tombstone never retains stale original document', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final original = await repository.createNotebook();
    var copiedToServer = false;
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
        if (request.method == 'PUT' &&
            request.url.path.startsWith('/v1/sync/notebooks/')) {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          expect(payload['expectedRevision'], 0);
          expect(payload['notebook']['uid'], isNot(original.uid));
          copiedToServer = true;
          return http.Response('{"revision":1}', 200);
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
    expect(saved, hasLength(1));
    expect(saved.single.uid, isNot(original.uid));
    expect(saved.single.title, '${original.title} (1)');
    expect(copiedToServer, isTrue);
  });
}
