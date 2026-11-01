import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/backup/remote_backup_scheduler.dart';
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
    'uploads a complete snapshot and accepts only verified finalize',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      await repository.createNotebook();
      final values = <String, String>{
        'library_folders.json': jsonEncode({
          'folders': ['Notes'],
          'plannerTasks': <String, dynamic>{},
        }),
        'study_planner.json': jsonEncode({
          'version': 1,
          'sessions': <dynamic>[],
        }),
      };
      textStorageReadOverride = (key) async => values[key];
      textStorageWriteOverride = (key, value) async => values[key] = value;

      var call = 0;
      List<int>? uploaded;
      final apiClient = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          call++;
          if (call == 1) {
            return http.Response(
              jsonEncode({
                'accessToken': 'access',
                'refreshToken': 'refresh-token-with-at-least-forty-characters',
                'expiresIn': 600,
                'userId': 'user-1',
                'username': 'test_user',
              }),
              200,
            );
          }
          if (call == 2) {
            return http.Response(
              jsonEncode({'backupId': 'backup-1', 'status': 'pending'}),
              201,
            );
          }
          if (call == 3) {
            uploaded = request.bodyBytes;
            return http.Response('', 204);
          }
          final bytes = uploaded!;
          return http.Response(
            jsonEncode({
              'backupId': 'backup-1',
              'status': 'verified',
              'sha256': sha256.convert(bytes).toString(),
              'verifiedAt': '2026-10-26T12:00:00Z',
            }),
            200,
          );
        }),
      );
      final session = AccountSessionController(apiClient);
      await session.login('test_user', 'a-secure-password');
      final service = RemoteBackupService(
        repository: repository,
        apiClient: apiClient,
        session: session,
      );

      final receipt = await service.uploadVerifiedSnapshot(
        deviceId: '123e4567-e89b-12d3-a456-426614174000',
      );

      final envelope =
          jsonDecode(utf8.decode(uploaded!)) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      expect(envelope['version'], 2);
      expect(payload['notebooks'], hasLength(1));
      expect(payload['libraryState'], containsPair('folders', ['Notes']));
      expect(payload['studyPlannerState'], containsPair('sessions', isEmpty));
      expect(receipt.backupId, 'backup-1');
      expect(call, 4);
    },
  );

  test('keeps a backup dirty when data changes during upload', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    await repository.createNotebook();
    final values = <String, String>{};
    textStorageReadOverride = (key) async => values[key];
    textStorageWriteOverride = (key, value) async => values[key] = value;

    var call = 0;
    late RemoteBackupScheduler scheduler;
    List<int>? uploaded;
    final apiClient = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        call++;
        if (call == 1) {
          return http.Response(
            jsonEncode({
              'accessToken': 'access',
              'refreshToken': 'refresh-token-with-at-least-forty-characters',
              'expiresIn': 600,
              'userId': 'user-1',
              'username': 'test_user',
            }),
            200,
          );
        }
        if (call == 2) {
          return http.Response(
            jsonEncode({'backupId': 'backup-1', 'status': 'pending'}),
            201,
          );
        }
        if (call == 3) {
          uploaded = request.bodyBytes;
          scheduler.markDirty();
          return http.Response('', 204);
        }
        return http.Response(
          jsonEncode({
            'backupId': 'backup-1',
            'status': 'verified',
            'sha256': sha256.convert(uploaded!).toString(),
            'verifiedAt': '2026-10-26T12:00:00Z',
          }),
          200,
        );
      }),
    );
    final session = AccountSessionController(apiClient);
    await session.login('test_user', 'a-secure-password');
    scheduler = RemoteBackupScheduler(
      service: RemoteBackupService(
        repository: repository,
        apiClient: apiClient,
        session: session,
      ),
      session: session,
    );
    addTearDown(scheduler.dispose);
    scheduler.enableForSignedInAccount();

    await scheduler.uploadNow();

    expect(scheduler.lastVerifiedBackup, isNotNull);
    expect(scheduler.hasPendingBackup, isTrue);
  });

  test('isolates status and device identity between accounts', () async {
    final values = <String, String>{};
    textStorageReadOverride = (key) async => values[key];
    textStorageWriteOverride = (key, value) async => values[key] = value;
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final apiClient = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final isAccountA = body['username'] == 'account_a';
        return http.Response(
          jsonEncode({
            'accessToken': isAccountA ? 'access-a' : 'access-b',
            'refreshToken': 'refresh-token-with-at-least-forty-characters',
            'expiresIn': 600,
            'userId': isAccountA ? 'user-a' : 'user-b',
            'username': body['username'],
          }),
          200,
        );
      }),
    );
    final session = AccountSessionController(apiClient);
    await session.login('account_a', 'a-secure-password');
    final service = _RecordingRemoteBackupService(
      repository: repository,
      apiClient: apiClient,
      session: session,
    );
    final scheduler = RemoteBackupScheduler(service: service, session: session);
    addTearDown(scheduler.dispose);

    scheduler.enableForSignedInAccount();
    await scheduler.uploadNow();
    expect(scheduler.lastVerifiedBackup, isNotNull);
    await scheduler.stop();
    session.useLocalOnly();

    await session.login('account_b', 'b-secure-password');
    expect(scheduler.lastVerifiedBackup, isNull);
    expect(scheduler.lastError, isNull);
    scheduler.enableForSignedInAccount();
    await scheduler.uploadNow();

    expect(service.deviceIds, hasLength(2));
    expect(service.deviceIds[0], isNot(service.deviceIds[1]));
    expect(
      values.keys.where((key) => key.startsWith('server_device_')),
      hasLength(2),
    );
    expect(values, isNot(contains('server_device.json')));
  });
}

class _RecordingRemoteBackupService extends RemoteBackupService {
  _RecordingRemoteBackupService({
    required super.repository,
    required super.apiClient,
    required super.session,
  });

  final deviceIds = <String>[];

  @override
  Future<RemoteBackupReceipt> uploadVerifiedSnapshot({
    required String deviceId,
  }) async {
    deviceIds.add(deviceId);
    return RemoteBackupReceipt(
      backupId: 'backup-${deviceIds.length}',
      checksum: 'checksum-${deviceIds.length}',
      verifiedAt: DateTime.utc(2026, 10, 30, 12, deviceIds.length),
    );
  }
}
