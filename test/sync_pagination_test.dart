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
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

Map<String, dynamic> record(int number) {
  final uid = 'uid-${number.toString().padLeft(3, '0')}';
  final notebook = Notebook(
    uid: uid,
    title: 'Remote $number',
    kind: NotebookKind.notebook,
    folder: 'Notes',
    createdAt: DateTime.utc(2026, 11, 2),
    updatedAt: DateTime.utc(2026, 11, 2),
    pages: [
      NotePage(
        id: 'page-$number',
        title: 'Page',
        textBlocks: [],
        imageBlocks: [],
        inkStrokes: [],
        isBookmarked: false,
      ),
    ],
  );
  return {
    'uid': uid,
    'revision': 1,
    'deleted': false,
    'notebook': NotebookRepository.encodeNotebook(notebook),
  };
}

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

  test(
    'all bootstrap and change pages are imported with original cursor',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final requested = <String>[];
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          requested.add(request.url.toString());
          if (request.url.path == '/v1/sync/bootstrap') {
            final after = request.url.queryParameters['after'];
            if (after == null) {
              return http.Response(
                jsonEncode({
                  'cursor': 10,
                  'notebooks': [record(0), record(1), record(2)],
                  'next': 'uid-002',
                }),
                200,
              );
            }
            expect(after, 'uid-002');
            return http.Response(
              jsonEncode({
                'cursor': 11,
                'notebooks': [record(3), record(4), record(5)],
                'next': null,
              }),
              200,
            );
          }
          if (request.url.path == '/v1/sync/changes') {
            final after = request.url.queryParameters['after'];
            if (after == '10') {
              return http.Response(
                jsonEncode({
                  'cursor': 12,
                  'changes': [record(6), record(7)],
                  'hasMore': true,
                }),
                200,
              );
            }
            expect(after, '12');
            return http.Response(
              jsonEncode({
                'cursor': 13,
                'changes': [record(8)],
                'hasMore': false,
              }),
              200,
            );
          }
          fail('Unexpected request: ${request.url}');
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

      expect(sync.lastError, isNull);
      final loaded = await repository.fetchNotebooks();
      expect(loaded, hasLength(9));
      expect(loaded.map((entry) => entry.uid).toSet(), hasLength(9));
      expect(requested.where((url) => url.contains('/bootstrap')), hasLength(2));
      expect(requested.where((url) => url.contains('/changes')), hasLength(2));
      expect(sync.hasPendingChanges, isFalse);
    },
  );
}
