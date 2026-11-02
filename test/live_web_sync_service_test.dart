import 'dart:async';
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
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

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

  test('local and UTC timestamps do not create a sync conflict', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final created = await repository.createNotebook();
    final notebook = (await repository.getNotebook(created.uid))!;
    final remote = NotebookRepository.encodeNotebook(notebook)
      ..['createdAt'] = notebook.createdAt
          .toUtc()
          .toIso8601String()
          .replaceFirst('Z', '+00:00')
      ..['updatedAt'] = notebook.updatedAt
          .toUtc()
          .toIso8601String()
          .replaceFirst('Z', '+00:00');
    var allowWrite = false;
    var writes = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response(
            jsonEncode({
              'cursor': 1,
              'notebooks': [
                {
                  'uid': notebook.uid,
                  'revision': 1,
                  'deleted': false,
                  'notebook': remote,
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"cursor":1,"changes":[]}', 200);
        }
        if (allowWrite && request.method == 'PUT') {
          writes++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['baseNotebook'], remote);
          expect(body['expectedRevision'], 1);
          expect(body['notebook']['createdAt'], remote['createdAt']);
          return http.Response(
            jsonEncode({'revision': 2, 'notebook': body['notebook']}),
            200,
          );
        }
        fail('Unchanged timestamps must not produce a write.');
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
    final saved = await repository.fetchNotebooks();
    expect(saved, hasLength(1));
    expect(saved.single.uid, notebook.uid);
    expect(sync.hasPendingChanges, isFalse);

    allowWrite = true;
    await repository.saveNotebook(notebook.copyWith(title: 'Edited locally'));
    sync.enqueue([NotebookRepositoryChange.full(notebook.uid)]);
    await sync.syncNow();
    expect(sync.lastError, isNull);
    expect(writes, 1);
    expect(sync.hasPendingChanges, isFalse);
  });

  test('bootstrap uses remote document without creating a duplicate', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final original = await repository.createNotebook(title: 'Course');
    final remote = original.copyWith(
      pages: [original.pages.single.copyWith(title: 'Server version')],
    );
    final writes = <Map<String, dynamic>>[];
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
                  'revision': 1,
                  'deleted': false,
                  'notebook': NotebookRepository.encodeNotebook(remote),
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"cursor":1,"changes":[]}', 200);
        }
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          writes.add(body);
          return http.Response(
            jsonEncode({'revision': (body['expectedRevision'] as int) + 1}),
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
    expect(writes, isEmpty);
    final notebooks = await repository.fetchNotebooks();
    expect(notebooks, hasLength(1));
    expect(notebooks.single.uid, original.uid);
    expect(notebooks.single.pages.single.title, 'Server version');
  });

  test('uploads a conflict copy in the same pass after a 409', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final created = await repository.createNotebook(title: 'Course');
    final original = (await repository.getNotebook(created.uid))!;
    final remote = original.copyWith(title: 'Remote edit');
    final writes = <Map<String, dynamic>>[];
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
                  'revision': 1,
                  'deleted': false,
                  'notebook': NotebookRepository.encodeNotebook(original),
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"cursor":1,"changes":[]}', 200);
        }
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          writes.add(body);
          if (body['notebook']['uid'] == original.uid) {
            return http.Response(
              jsonEncode({
                'detail': {
                  'uid': original.uid,
                  'revision': 2,
                  'deleted': false,
                  'notebook': NotebookRepository.encodeNotebook(remote),
                },
              }),
              409,
            );
          }
          expect(body['expectedRevision'], 0);
          return http.Response(
            jsonEncode({'revision': 1, 'notebook': body['notebook']}),
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
    expect(writes, isEmpty);
    final edited = original.copyWith(
      title: 'Local edit',
      updatedAt: original.updatedAt.add(const Duration(minutes: 1)),
    );
    expect(await repository.saveNotebook(edited), isTrue);
    sync.enqueue([NotebookRepositoryChange.full(original.uid)]);
    await sync.syncNow();

    expect(sync.lastError, isNull);
    expect(sync.hasPendingChanges, isFalse);
    expect(writes, hasLength(2));
    final notebooks = await repository.fetchNotebooks();
    expect(notebooks, hasLength(2));
    expect(
      notebooks.singleWhere((item) => item.uid == original.uid).title,
      'Remote edit',
    );
    final copy = notebooks.singleWhere((item) => item.uid != original.uid);
    expect(copy.title, 'Local edit (1)');
    expect(copy.folder, original.folder);
    expect(copy.pages.single.id, isNot(original.pages.single.id));
    expect(writes.last['notebook']['uid'], copy.uid);
  });

  test(
    'remote tombstone deletes unchanged local note without a copy',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final note = await repository.createNotebook(title: 'Deleted remotely');
      var writes = 0;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/sync/bootstrap') {
            return http.Response(
              jsonEncode({
                'cursor': 1,
                'notebooks': [
                  {
                    'uid': note.uid,
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
          writes++;
          fail('A confirmed deletion must not be re-uploaded.');
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
      expect(await repository.fetchNotebooks(), isEmpty);
      expect(sync.hasPendingChanges, isFalse);
      expect(writes, 0);
    },
  );

  test('a later offline edit restores the original deleted UID', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final note = await repository.createNotebook(title: 'Shared draft');
    final persisted = (await repository.getNotebook(note.uid))!;
    var rejectUpdate = false;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response(
            jsonEncode({
              'cursor': 1,
              'notebooks': [
                {
                  'uid': note.uid,
                  'revision': 1,
                  'deleted': false,
                  'notebook': NotebookRepository.encodeNotebook(persisted),
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"cursor":1,"changes":[]}', 200);
        }
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (rejectUpdate &&
              body['notebook']['uid'] == note.uid &&
              body['restoreDeleted'] != true) {
            return http.Response(
              jsonEncode({
                'detail': {
                  'uid': note.uid,
                  'revision': 2,
                  'deleted': true,
                  'notebook': null,
                },
              }),
              409,
            );
          }
          return http.Response(
            jsonEncode({
              'revision': body['restoreDeleted'] == true ? 3 : 1,
              'notebook': body['notebook'],
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
    rejectUpdate = true;
    await repository.saveNotebook(note.copyWith(title: 'Edited offline'));
    sync.enqueue([NotebookRepositoryChange.full(note.uid)]);
    await sync.syncNow();

    final remaining = await repository.fetchNotebooks();
    expect(remaining, hasLength(1));
    expect(remaining.single.uid, note.uid);
    expect(remaining.single.title, 'Edited offline');
    expect(sync.hasPendingChanges, isFalse);
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

  test(
    'guest changes replace original without creating conflict copies',
    () async {
      final now = DateTime.utc(2026, 11, 1, 12);
      final initial = Notebook(
        uid: 'shared-uid',
        title: 'Shared document',
        kind: NotebookKind.notebook,
        folder: 'Studies',
        createdAt: now,
        updatedAt: now,
        pages: [
          NotePage(
            id: 'page-1',
            title: 'Page',
            textBlocks: [],
            imageBlocks: [],
            inkStrokes: [],
            isBookmarked: false,
          ),
        ],
      );
      final changed = initial.copyWith(
        updatedAt: now.add(const Duration(minutes: 1)),
        pages: [initial.pages.single.copyWith(isBookmarked: true)],
      );
      var polls = 0;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/login') {
            return _sessionResponse(username: 'owner');
          }
          if (request.url.path == '/v1/sync/bootstrap') {
            return http.Response(
              jsonEncode({
                'cursor': 0,
                'notebooks': [
                  {
                    'uid': initial.uid,
                    'revision': 1,
                    'deleted': false,
                    'notebook': NotebookRepository.encodeNotebook(initial),
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/v1/sync/changes') {
            polls++;
            return http.Response(
              jsonEncode(
                polls == 1
                    ? {'cursor': 0, 'changes': []}
                    : {
                        'cursor': 1,
                        'changes': [
                          {
                            'uid': initial.uid,
                            'revision': 2,
                            'deleted': false,
                            'notebook': NotebookRepository.encodeNotebook(
                              changed,
                            ),
                          },
                        ],
                      },
              ),
              200,
            );
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      final session = AccountSessionController(client);
      await session.login('owner', 'password123');
      final database = NotesDatabase(NativeDatabase.memory());
      final repository = NotebookRepository(database);
      final sync = LiveWebSyncService(
        repository: repository,
        apiClient: client,
        session: session,
      );
      addTearDown(() async {
        sync.dispose();
        session.dispose();
        await database.close();
        client.close();
      });
      await sync.start(InitialSyncPolicy.downloadRemote);
      final epoch = sync.remoteApplyEpoch;
      await sync.syncNow();

      final stored = await repository.fetchNotebooks();
      expect(stored, hasLength(1));
      expect(stored.single.uid, 'shared-uid');
      expect(stored.single.pages.single.isBookmarked, isTrue);
      expect(sync.remoteApplyEpoch, greaterThan(epoch));
    },
  );

  test(
    'host and guest edits merge into the original without extra copies',
    () async {
      final now = DateTime.utc(2026, 11, 1, 12);
      final initial = Notebook(
        uid: 'shared-host-document',
        title: 'Shared document',
        kind: NotebookKind.board,
        folder: 'Meeting',
        createdAt: now,
        updatedAt: now,
        pages: [
          NotePage(
            id: 'page-1',
            title: 'Page',
            textBlocks: [],
            imageBlocks: [],
            inkStrokes: [],
            isBookmarked: false,
          ),
        ],
      );
      final guest = initial.copyWith(
        updatedAt: now.add(const Duration(seconds: 1)),
        pages: [initial.pages.single.copyWith(isBookmarked: true)],
      );
      final owner = initial.copyWith(
        updatedAt: now.add(const Duration(seconds: 2)),
        pages: [initial.pages.single.copyWith(title: 'Host change')],
      );
      final merged = owner.copyWith(
        pages: [owner.pages.single.copyWith(isBookmarked: true)],
      );
      var changeRequests = 0;
      var ownerWriteSent = false;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/login') {
            return _sessionResponse(username: 'owner');
          }
          if (request.url.path == '/v1/sync/bootstrap') {
            return http.Response(
              jsonEncode({
                'cursor': 0,
                'notebooks': [
                  {
                    'uid': initial.uid,
                    'revision': 1,
                    'deleted': false,
                    'notebook': NotebookRepository.encodeNotebook(initial),
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/v1/sync/changes') {
            changeRequests++;
            if (changeRequests == 1) {
              return http.Response(
                jsonEncode({'cursor': 0, 'changes': []}),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'cursor': 2,
                'changes': [
                  {
                    'uid': initial.uid,
                    'revision': 2,
                    'deleted': false,
                    'notebook': NotebookRepository.encodeNotebook(guest),
                  },
                ],
              }),
              200,
            );
          }
          if (request.method == 'PUT' &&
              request.url.path == '/v1/sync/notebooks/${initial.uid}') {
            ownerWriteSent = true;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['expectedRevision'], 1);
            expect(
              body['baseNotebook'],
              NotebookRepository.encodeNotebook(initial),
            );
            expect(body['notebook'], NotebookRepository.encodeNotebook(owner));
            return http.Response(
              jsonEncode({
                'revision': 3,
                'cursor': 2,
                'notebook': NotebookRepository.encodeNotebook(merged),
              }),
              200,
            );
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      final database = NotesDatabase(NativeDatabase.memory());
      final repository = NotebookRepository(database);
      final session = AccountSessionController(client);
      await session.login('owner', 'password123');
      final sync = LiveWebSyncService(
        repository: repository,
        apiClient: client,
        session: session,
      );
      addTearDown(() async {
        sync.dispose();
        session.dispose();
        await database.close();
        client.close();
      });
      await sync.start(InitialSyncPolicy.downloadRemote);
      await repository.saveNotebook(owner);
      sync.enqueue([NotebookRepositoryChange.full(initial.uid)]);
      await sync.syncNow();

      expect(ownerWriteSent, isTrue);
      expect(sync.lastError, isNull);
      final notebooks = await repository.fetchNotebooks();
      expect(notebooks, hasLength(1));
      expect(notebooks.single.uid, initial.uid);
      expect(notebooks.single.folder, 'Meeting');
      expect(notebooks.single.pages.single.title, 'Host change');
      expect(notebooks.single.pages.single.isBookmarked, isTrue);
    },
  );

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

  test('passive device downloads remote edits without local writes', () async {
    final remote = Notebook(
      uid: 'from-device-a',
      title: 'Edited on device A',
      kind: NotebookKind.notebook,
      folder: 'Courses',
      createdAt: DateTime.utc(2026, 11, 2),
      updatedAt: DateTime.utc(2026, 11, 2, 12),
      pages: [
        NotePage(
          id: 'remote-page',
          title: 'Remote content',
          textBlocks: [],
          imageBlocks: [],
          inkStrokes: [],
          isBookmarked: false,
        ),
      ],
    );
    var remoteChanged = false;
    var imported = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response('{"cursor":0,"notebooks":[]}', 200);
        }
        if (request.url.path == '/v1/sync/changes') {
          if (!remoteChanged) {
            return http.Response('{"cursor":0,"changes":[]}', 200);
          }
          return http.Response(
            jsonEncode({
              'cursor': 1,
              'changes': [
                {
                  'uid': remote.uid,
                  'revision': 1,
                  'deleted': false,
                  'notebook': NotebookRepository.encodeNotebook(remote),
                },
              ],
            }),
            200,
          );
        }
        fail('Passive device must not upload an unchanged notebook.');
      }),
    )..setAccessToken('token');
    addTearDown(client.close);
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(
      database,
      onChanged: (changes) => imported += changes.length,
    );
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'passive-device';
    addTearDown(session.dispose);
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
      enableRealtime: false,
    );
    addTearDown(sync.dispose);
    await sync.start(InitialSyncPolicy.downloadRemote);
    expect(imported, 0);
    expect(sync.hasPendingChanges, isFalse);

    remoteChanged = true;
    await sync.syncNow();

    expect(sync.lastError, isNull);
    expect(imported, 1);
    expect(sync.hasPendingChanges, isFalse);
    final notebooks = await repository.fetchNotebooks();
    expect(notebooks.single.uid, remote.uid);
    expect(notebooks.single.pages.single.title, 'Remote content');
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

  test('bootstrap preserves a pending local edit', () async {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final created = await repository.createNotebook(title: 'Existing');
    final notebook = (await repository.getNotebook(created.uid))!;
    final bootstrapStarted = Completer<void>();
    final releaseBootstrap = Completer<void>();
    var writes = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/bootstrap') {
          bootstrapStarted.complete();
          await releaseBootstrap.future;
          return http.Response(
            jsonEncode({
              'cursor': 1,
              'notebooks': [
                {
                  'uid': notebook.uid,
                  'revision': 1,
                  'deleted': false,
                  'notebook': NotebookRepository.encodeNotebook(notebook),
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"cursor":1,"changes":[]}', 200);
        }
        if (request.method == 'PUT') {
          writes++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['expectedRevision'], 1);
          expect(body['notebook']['uid'], notebook.uid);
          return http.Response(
            jsonEncode({'revision': 2, 'notebook': body['notebook']}),
            200,
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    )..setAccessToken('token');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'bootstrap-race';
    addTearDown(session.dispose);
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
      enableRealtime: false,
    );
    addTearDown(sync.dispose);

    final starting = sync.start(InitialSyncPolicy.mergeSafely);
    await bootstrapStarted.future;
    sync.enqueue([NotebookRepositoryChange.full(notebook.uid)]);
    releaseBootstrap.complete();
    await starting;

    expect(sync.lastError, isNull);
    expect(writes, 1);
    expect(sync.hasPendingChanges, isFalse);
    await sync.stop();
    final persisted = stored.values
        .where((value) => value.contains('"pending"'))
        .single;
    expect(jsonDecode(persisted)['pending'], isEmpty);
  });

  test('overlapping outbox writes preserve the latest pending UIDs', () async {
    final stored = <String, String>{};
    final releaseFirst = Completer<void>();
    final firstStarted = Completer<void>();
    final firstFinished = Completer<void>();
    var blockNext = false;
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async {
      if (key.startsWith('server_sync_state_') && blockNext) {
        blockNext = false;
        firstStarted.complete();
        await releaseFirst.future;
        stored[key] = value;
        firstFinished.complete();
        return;
      }
      stored[key] = value;
    };
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response('{"cursor":0,"notebooks":[]}', 200);
        }
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"cursor":0,"changes":[]}', 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    )..setAccessToken('token');
    addTearDown(client.close);
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'outbox-write-order';
    addTearDown(session.dispose);
    final sync = LiveWebSyncService(
      repository: repository,
      apiClient: client,
      session: session,
      enableRealtime: false,
    );
    addTearDown(sync.dispose);
    await sync.start(InitialSyncPolicy.downloadRemote);

    blockNext = true;
    final first = await repository.createNotebook(title: 'First');
    sync.enqueue([NotebookRepositoryChange.full(first.uid)]);
    await firstStarted.future;
    final second = await repository.createNotebook(title: 'Second');
    sync.enqueue([NotebookRepositoryChange.full(second.uid)]);
    // Allow the second write to overtake the first in the old implementation.
    await Future<void>.delayed(Duration.zero);
    releaseFirst.complete();
    await firstFinished.future;
    await sync.stop();

    final state =
        jsonDecode(
              stored.values.singleWhere((value) => value.contains('"pending"')),
            )
            as Map<String, dynamic>;
    expect(state['pending'], containsAll([first.uid, second.uid]));
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
