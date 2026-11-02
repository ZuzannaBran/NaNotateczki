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
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test(
    'verified account backup moves notes and settings to device two',
    () async {
      final stored = <String, String>{
        'library_folders.json': '{"folders":["School"],"plannerTasks":{}}',
        'study_planner.json': '{"version":1,"sessions":[]}',
        'app_prefs.json': '{"darkMode":true,"uiScale":1.25}',
        'shared_recent_colors.json': '[4278190335,4294901760]',
      };
      final accountSuffix = sha256
          .convert(utf8.encode('account-1'))
          .toString()
          .substring(0, 16);
      final idleKey = 'server_backup_preferences_$accountSuffix.json';
      stored[idleKey] = '{"version":1,"idleSeconds":900}';
      textStorageReadOverride = (key) async => stored[key];
      textStorageWriteOverride = (key, value) async => stored[key] = value;

      final db1 = NotesDatabase(NativeDatabase.memory());
      addTearDown(db1.close);
      final repo1 = NotebookRepository(db1);
      final notebook = await repo1.createNotebook();
      final deviceId = '123e4567-e89b-12d3-a456-426614174000';
      final backupId = '123e4567-e89b-12d3-a456-426614174001';
      List<int>? bytes;
      final client1 = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/v1/backups') {
            return http.Response(jsonEncode({'backupId': backupId}), 201);
          }
          if (request.url.path.endsWith('/content')) {
            bytes = request.bodyBytes;
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/finalize')) {
            return http.Response(
              jsonEncode({
                'status': 'verified',
                'sha256': sha256.convert(bytes!).toString(),
                'verifiedAt': '2026-11-01T12:00:00Z',
              }),
              200,
            );
          }
          fail('Unexpected upload endpoint');
        }),
      )..setAccessToken('token');
      addTearDown(client1.close);
      final session1 = AccountSessionController(client1)
        ..mode = AccountDataMode.account
        ..userId = 'account-1';
      addTearDown(session1.dispose);
      await RemoteBackupService(
        repository: repo1,
        apiClient: client1,
        session: session1,
      ).uploadVerifiedSnapshot(deviceId: deviceId);

      final uploaded = jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>;
      final payload = uploaded['payload'] as Map<String, dynamic>;
      expect(payload['backupPreferences']['idleSeconds'], 900);
      expect(payload['appPreferences']['darkMode'], true);
      expect(payload['recentColors'], [4278190335, 4294901760]);

      stored.clear();
      final db2 = NotesDatabase(NativeDatabase.memory());
      addTearDown(db2.close);
      final repo2 = NotebookRepository(db2);
      var downloads = 0;
      var backupListings = 0;
      var latestBackupId = backupId;
      var bootstrapCursor = 0;
      final client2 = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/backups') {
            backupListings++;
            return http.Response(
              jsonEncode({
                'backups': [
                  {
                    'backupId': latestBackupId,
                    'deviceId': deviceId,
                    'sha256': sha256.convert(bytes!).toString(),
                    'sizeBytes': bytes!.length,
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/download')) {
            downloads++;
            return http.Response.bytes(bytes!, 200);
          }
          if (request.url.path == '/v1/sync/bootstrap') {
            return http.Response(
              jsonEncode({'cursor': bootstrapCursor, 'notebooks': []}),
              200,
            );
          }
          fail('Unexpected recovery endpoint');
        }),
      )..setAccessToken('token');
      addTearDown(client2.close);
      final session2 = AccountSessionController(client2)
        ..mode = AccountDataMode.account
        ..userId = 'account-1';
      addTearDown(session2.dispose);
      final recovery = RemoteBackupService(
        repository: repo2,
        apiClient: client2,
        session: session2,
      );
      expect(await recovery.hydrateFromLatestAccountBackup(), true);
      expect((await repo2.fetchNotebooks()).single.uid, notebook.uid);
      expect(jsonDecode(stored['app_prefs.json']!)['darkMode'], true);
      expect(jsonDecode(stored[idleKey]!)['idleSeconds'], 900);

      stored['app_prefs.json'] = '{"darkMode":false}';
      await recovery.hydrateFromLatestAccountBackup();
      expect(jsonDecode(stored['app_prefs.json']!)['darkMode'], false);
      expect(downloads, 2);
      expect(backupListings, 2);
      expect((await repo2.fetchNotebooks()).single.uid, notebook.uid);

      // A later verified snapshot must be restored on the next sign-in.
      latestBackupId = '123e4567-e89b-12d3-a456-426614174002';
      stored.remove('app_prefs.json');
      expect(await recovery.hydrateFromLatestAccountBackup(), true);
      expect(downloads, 3);
      expect(backupListings, 3);
      expect(jsonDecode(stored['app_prefs.json']!)['darkMode'], true);
      expect((await repo2.fetchNotebooks()).single.uid, notebook.uid);

      // An intentional offline deletion must not be resurrected by either
      // the same snapshot or a newly uploaded snapshot from another device.
      await repo2.deleteNotebook(notebook.uid);
      await recovery.hydrateFromLatestAccountBackup();
      expect(await repo2.getNotebook(notebook.uid), isNull);
      stored['server_sync_state_$accountSuffix.json'] = jsonEncode({
        'version': 1,
        'pending': [notebook.uid],
      });
      latestBackupId = '123e4567-e89b-12d3-a456-426614174003';
      await recovery.hydrateFromLatestAccountBackup();
      expect(await repo2.getNotebook(notebook.uid), isNull);

      stored.clear();
      bootstrapCursor = 1;
      final db3 = NotesDatabase(NativeDatabase.memory());
      addTearDown(db3.close);
      final repo3 = NotebookRepository(db3);
      final recovery3 = RemoteBackupService(
        repository: repo3,
        apiClient: client2,
        session: session2,
      );
      await recovery3.hydrateFromLatestAccountBackup();
      expect(await repo3.fetchNotebooks(), isEmpty);

      stored.clear();
      stored['app_prefs.json'] = '{"darkMode":false}';
      stored['library_folders.json'] = '{"folders":["Local work"]}';
      final local = await repo3.createNotebook();
      await recovery3.hydrateFromLatestAccountBackup();
      expect((await repo3.fetchNotebooks()).single.uid, local.uid);
      expect(await repo3.getNotebook(notebook.uid), isNull);
      expect(jsonDecode(stored['app_prefs.json']!)['darkMode'], false);
      expect(
        jsonDecode(stored['library_folders.json']!)['folders'],
        containsAll(['Local work', 'School']),
      );
    },
  );

  test(
    'rejects invalid backup identifier before downloading or writing',
    () async {
      final stored = <String, String>{};
      textStorageReadOverride = (key) async => stored[key];
      textStorageWriteOverride = (key, value) async => stored[key] = value;
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      var requests = 0;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.path, '/v1/backups');
          return http.Response(
            jsonEncode({
              'backups': [
                {
                  'backupId': '123e4567-e89b-12d3-a456-426614174001/extra',
                  'sha256': 'unused',
                  'sizeBytes': 100,
                },
              ],
            }),
            200,
          );
        }),
      )..setAccessToken('token');
      addTearDown(client.close);
      final session = AccountSessionController(client)
        ..mode = AccountDataMode.account
        ..userId = 'account-1';
      addTearDown(session.dispose);

      await expectLater(
        RemoteBackupService(
          repository: repository,
          apiClient: client,
          session: session,
        ).hydrateFromLatestAccountBackup(),
        throwsA(isA<FormatException>()),
      );

      expect(requests, 1);
      expect(await repository.fetchNotebooks(), isEmpty);
      expect(stored, isEmpty);
    },
  );

  test('rejects tampered backup before writing any account data', () async {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = NotebookRepository(db);
    final bytes = utf8.encode('{"broken":true}');
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/backups') {
          return http.Response(
            jsonEncode({
              'backups': [
                {
                  'backupId': '123e4567-e89b-12d3-a456-426614174001',
                  'deviceId': '123e4567-e89b-12d3-a456-426614174000',
                  'sha256': 'invalid-checksum',
                  'sizeBytes': bytes.length,
                },
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(bytes, 200);
      }),
    )..setAccessToken('token');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-1';
    addTearDown(session.dispose);
    await expectLater(
      RemoteBackupService(
        repository: repository,
        apiClient: client,
        session: session,
      ).hydrateFromLatestAccountBackup(),
      throwsA(isA<FormatException>()),
    );
    expect(await repository.fetchNotebooks(), isEmpty);
    expect(stored, isEmpty);
  });
}
