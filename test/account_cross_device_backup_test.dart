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

  test('verified account backup moves notes and settings to device two',
      () async {
    final stored = <String, String>{
      'library_folders.json': '{"folders":["School"],"plannerTasks":{}}',
      'study_planner.json': '{"version":1,"sessions":[]}',
      'app_prefs.json': '{"darkMode":true,"uiScale":1.25}',
      'shared_recent_colors.json': '[4278190335,4294901760]',
    };
    final idleKey = 'server_backup_preferences_' +
        sha256.convert(utf8.encode('account-1')).toString().substring(0, 16) +
        '.json';
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
        if (request.method == 'POST' &&
            request.url.path == '/v1/backups') {
          return http.Response(jsonEncode({'backupId': backupId}), 201);
        }
        if (request.url.path.endsWith('/content')) {
          bytes = request.bodyBytes;
          return http.Response('', 204);
        }
        if (request.url.path.endsWith('/finalize')) {
          return http.Response(jsonEncode({
            'status': 'verified',
            'sha256': sha256.convert(bytes!).toString(),
            'verifiedAt': '2026-11-01T12:00:00Z',
          }), 200);
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
    final client2 = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/backups') {
          return http.Response(jsonEncode({
            'backups': [{
              'backupId': backupId,
              'deviceId': deviceId,
              'sha256': sha256.convert(bytes!).toString(),
              'sizeBytes': bytes!.length,
            }],
          }), 200);
        }
        if (request.url.path.endsWith('/download')) {
          return http.Response.bytes(bytes!, 200);
        }
        if (request.url.path == '/v1/sync/bootstrap') {
          return http.Response('{"cursor":0,"notebooks":[]}', 200);
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
  });

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
          return http.Response(jsonEncode({
            'backups': [{
              'backupId': '123e4567-e89b-12d3-a456-426614174001',
              'deviceId': '123e4567-e89b-12d3-a456-426614174000',
              'sha256': 'invalid-checksum',
              'sizeBytes': bytes.length,
            }],
          }), 200);
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
