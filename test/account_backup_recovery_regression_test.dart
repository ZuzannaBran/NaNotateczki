import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/backup/remote_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

void main() {
  late Map<String, String> stored;
  setUp(() {
    stored = {};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
  });
  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test(
    'recovery verifies original numeric spelling, not re-encoded JSON',
    () async {
      final repo = _repository();
      final service = _service(
        repo,
        '{"notebooks":[],"libraryState":{},"studyPlannerState":{},'
        '"appPreferences":{"uiScale":1.0000}}',
      );
      expect(await service.hydrateFromLatestAccountBackup(), isTrue);
      expect(jsonDecode(stored['app_prefs.json']!)['uiScale'], 1);
    },
  );

  test(
    'populated library retains local work and numbers backup conflicts',
    () async {
      final repo = _repository();
      final local = await repo.createNotebook(title: 'Course');
      final reserved = await repo.createNotebook(title: 'Course (1)');
      final different = local.copyWith(
        pages: [local.pages.single.copyWith(title: 'From backup')],
      );
      final missing = local.copyWith(
        uid: 'backup-only',
        title: 'Another document',
        pages: [local.pages.single.copyWith(id: 'backup-only-page')],
      );
      final payload = jsonEncode({
        'notebooks': [
          different,
          missing,
          reserved,
        ].map(NotebookRepository.encodeNotebook).toList(),
        'libraryState': {},
        'studyPlannerState': {},
      });
      final service = _service(repo, payload);

      expect(await service.hydrateFromLatestAccountBackup(), isTrue);
      final saved = await repo.fetchNotebooks();
      expect(saved, hasLength(4));
      expect((await repo.getNotebook(local.uid))!.pages.single.title, 'Page 1');
      final copy = saved.singleWhere((note) => note.title == 'Course (2)');
      expect(copy.uid, isNot(local.uid));
      expect(copy.folder, local.folder);
      expect(copy.pages.single.title, 'From backup');
      expect(copy.pages.single.id, isNot(local.pages.single.id));
      expect(await repo.getNotebook(missing.uid), isNotNull);
      await service.hydrateFromLatestAccountBackup();
      expect(await repo.fetchNotebooks(), hasLength(4));
    },
  );

  test('payload checksum mismatch still refuses all writes', () async {
    final repo = _repository();
    final service = _service(
      repo,
      '{"notebooks":[],"libraryState":{},"studyPlannerState":{}}',
      checksum: 'invalid',
    );
    await expectLater(
      service.hydrateFromLatestAccountBackup(),
      throwsFormatException,
    );
    // Corrupt backups may be logged, but must not mutate account data.
    expect(stored.keys.where((key) => key != 'app_error_log.json'), isEmpty);
    expect(await repo.fetchNotebooks(), isEmpty);
  });

  test(
    'a newer backup draft is kept beside an existing account revision',
    () async {
      final source = await _repository().createNotebook(title: 'Course');
      final draft = source.copyWith(
        pages: [source.pages.single.copyWith(title: 'Backup draft')],
      );
      final repo = _repository();
      final service = _service(
        repo,
        jsonEncode({
          'notebooks': [NotebookRepository.encodeNotebook(draft)],
          'libraryState': {},
          'studyPlannerState': {},
        }),
        records: [
          {
            'uid': source.uid,
            'revision': 3,
            'deleted': false,
            'notebook': NotebookRepository.encodeNotebook(source),
          },
        ],
      );

      expect(await service.hydrateFromLatestAccountBackup(), isTrue);
      final recovered = (await repo.fetchNotebooks()).single;
      expect(recovered.title, 'Course (1)');
      expect(recovered.uid, isNot(source.uid));
      expect(recovered.folder, source.folder);
      expect(recovered.pages.single.title, 'Backup draft');
      expect(await repo.getNotebook(source.uid), isNull);
    },
  );

  test(
    'a tombstone still prevents a backup draft from resurrecting its UID',
    () async {
      final source = await _repository().createNotebook(title: 'Deleted');
      final repo = _repository();
      final service = _service(
        repo,
        jsonEncode({
          'notebooks': [NotebookRepository.encodeNotebook(source)],
          'libraryState': {},
          'studyPlannerState': {},
        }),
        records: [
          {'uid': source.uid, 'revision': 3, 'deleted': true, 'notebook': null},
        ],
      );

      await service.hydrateFromLatestAccountBackup();
      expect(await repo.fetchNotebooks(), isEmpty);
    },
  );

  test('tombstone on a later bootstrap page blocks stale backup replay',
      () async {
    final source = await _repository().createNotebook(title: 'Deleted');
    final repo = _repository();
    final service = _service(
      repo,
      jsonEncode({
        'notebooks': [NotebookRepository.encodeNotebook(source)],
        'libraryState': {},
        'studyPlannerState': {},
      }),
      bootstrapPageSize: 1,
      records: [
        {
          'uid': '!earlier',
          'revision': 1,
          'deleted': true,
          'notebook': null,
        },
        {
          'uid': source.uid,
          'revision': 3,
          'deleted': true,
          'notebook': null,
        },
      ],
    );

    await service.hydrateFromLatestAccountBackup();
    expect(await repo.fetchNotebooks(), isEmpty);
  });

  test(
    'a planner conflict keeps both task lists under their document IDs',
    () async {
      final repo = _repository();
      final planner = await repo.createPlanner(title: 'Tasks');
      stored['library_folders.json'] = jsonEncode({
        'folders': ['Local folder'],
        'plannerTasks': {
          planner.uid: [
            {'id': 'local-task', 'title': 'Local'},
          ],
        },
      });
      final service = _service(
        repo,
        jsonEncode({
          'notebooks': [NotebookRepository.encodeNotebook(planner)],
          'libraryState': {
            'folders': ['Backup folder'],
            'plannerTasks': {
              planner.uid: [
                {'id': 'backup-task', 'title': 'Backup'},
              ],
            },
          },
          'studyPlannerState': {},
        }),
      );

      await service.hydrateFromLatestAccountBackup();

      final docs = await repo.fetchNotebooks();
      expect(docs, hasLength(2));
      final copy = docs.singleWhere((note) => note.title == 'Tasks (1)');
      final library = jsonDecode(stored['library_folders.json']!);
      expect(
        library['folders'],
        containsAll(['Local folder', 'Backup folder']),
      );
      expect(library['plannerTasks'][planner.uid].single['title'], 'Local');
      expect(library['plannerTasks'][copy.uid].single['title'], 'Backup');
    },
  );
}

NotebookRepository _repository() {
  final database = NotesDatabase(NativeDatabase.memory());
  addTearDown(database.close);
  return NotebookRepository(database);
}

RemoteBackupService _service(
  NotebookRepository repo,
  String payload, {
  String? checksum,
  List<Map<String, dynamic>> records = const [],
  int? bootstrapPageSize,
}) {
  const deviceId = '123e4567-e89b-12d3-a456-426614174000';
  const backupId = '123e4567-e89b-12d3-a456-426614174001';
  final hash = checksum ?? sha256.convert(utf8.encode(payload)).toString();
  final bytes = utf8.encode(
    '{"format":"nanotateczki-server-backup","version":2,'
    '"checksumAlgorithm":"sha256","deviceId":"$deviceId",'
    '"checksum":"$hash","payload":$payload}',
  );
  final client = ApiClient(
    baseUri: Uri.parse('https://api.example.com'),
    httpClient: MockClient((request) async {
      if (request.url.path == '/v1/backups') {
        return http.Response(
          jsonEncode({
            'backups': [
              {
                'backupId': backupId,
                'deviceId': deviceId,
                'sha256': sha256.convert(bytes).toString(),
                'sizeBytes': bytes.length,
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/download')) {
        return http.Response.bytes(bytes, 200);
      }
      if (request.url.path == '/v1/sync/bootstrap') {
        final after = request.url.queryParameters['after'];
        final start = after == null
            ? 0
            : records.indexWhere((item) => item['uid'] == after) + 1;
        final batch = bootstrapPageSize == null
            ? records
            : records.skip(start).take(bootstrapPageSize).toList();
        final next = bootstrapPageSize != null &&
                start + batch.length < records.length
            ? batch.last['uid'] as String
            : null;
        return http.Response(
          jsonEncode({
            'cursor': records.isEmpty ? 0 : 1,
            'notebooks': batch,
            'next': next,
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
  return RemoteBackupService(
    repository: repo,
    apiClient: client,
    session: session,
  );
}
