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
import 'package:program/data/sync/account_credential_store.dart';
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
      final session = AccountSessionController(
        apiClient,
        credentialStore: _MemoryAccountCredentialStore(),
      );
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
      expect(envelope['accountId'], 'user-1');
      expect(envelope['schemaVersion'], database.schemaVersion);
      expect(envelope['operationCheckpoint'], isEmpty);
      expect(payload['notebooks'], hasLength(1));
      expect(payload['libraryState'], containsPair('folders', ['Notes']));
      expect(payload['studyPlannerState'], containsPair('sessions', isEmpty));
      expect(receipt.backupId, 'backup-1');
      expect(call, 4);
    },
  );

  test('unacknowledged operations cannot enter a checkpoint backup', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    await repository.createNotebook();
    await database.customStatement(
      'INSERT INTO operations (operation_id, actor_id, actor_seq, '
      'document_id, kind, envelope_json, logical_clock, schema_version, '
      'source, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'pending-operation',
        'actor',
        1,
        'document',
        'document.create',
        '{}',
        1,
        1,
        'local',
        0,
      ],
    );
    await database.customStatement(
      'INSERT INTO operation_outbox (operation_id, queued_at) '
      'VALUES (?, ?)',
      ['pending-operation', 0],
    );
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        fail('Pending operations must prevent backup upload.');
      }),
    )..setAccessToken('token');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'user-1';
    addTearDown(session.dispose);
    final service = RemoteBackupService(
      repository: repository,
      apiClient: client,
      session: session,
    );
    await expectLater(
      service.uploadVerifiedSnapshot(
        deviceId: '123e4567-e89b-12d3-a456-426614174000',
      ),
      throwsA(isA<StateError>()),
    );
    final pending = await database
        .customSelect('SELECT operation_id FROM operation_outbox')
        .get();
    expect(pending, hasLength(1));
  });

  test(
    'concurrent settings write aborts inconsistent backup capture',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      await repository.createNotebook();
      var reads = 0;
      textStorageReadOverride = (key) async {
        if (key != 'app_prefs.json') {
          return null;
        }
        reads++;
        return reads == 1 ? '{"darkMode":false}' : '{"darkMode":true}';
      };
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          fail('Mixed-state backup must not reach the server.');
        }),
      )..setAccessToken('token');
      addTearDown(client.close);
      final session = AccountSessionController(client)
        ..mode = AccountDataMode.account
        ..userId = 'user-1';
      addTearDown(session.dispose);
      final service = RemoteBackupService(
        repository: repository,
        apiClient: client,
        session: session,
      );
      await expectLater(
        service.uploadVerifiedSnapshot(
          deviceId: '123e4567-e89b-12d3-a456-426614174000',
        ),
        throwsA(isA<StateError>()),
      );
      expect(reads, 2);
    },
  );

  test('presence marker distinguishes new database from data loss', () async {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        fail('Database presence tracking must be offline.');
      }),
    );
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-a';
    addTearDown(session.dispose);
    final service = RemoteBackupService(
      repository: NotebookRepository(database),
      apiClient: client,
      session: session,
    );
    expect(await service.wasDatabaseInitialized('account-a'), isFalse);
    await service.markDatabaseInitialized('account-a');
    expect(await service.wasDatabaseInitialized('account-a'), isTrue);
    expect(await service.wasDatabaseInitialized('account-b'), isFalse);
    expect(stored, hasLength(1));
  });

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
    final session = AccountSessionController(
      apiClient,
      credentialStore: _MemoryAccountCredentialStore(),
    );
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

    await scheduler.backupNow();

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
    final deviceIds = <String>[];
    final sessionA = AccountSessionController(
      apiClient,
      credentialStore: _MemoryAccountCredentialStore(),
    );
    await sessionA.login('account_a', 'a-secure-password');
    final serviceA = _RecordingRemoteBackupService(
      repository: repository,
      apiClient: apiClient,
      session: sessionA,
      deviceIds: deviceIds,
    );
    final schedulerA = RemoteBackupScheduler(
      service: serviceA,
      session: sessionA,
    );
    addTearDown(schedulerA.dispose);

    schedulerA.enableForSignedInAccount();
    await schedulerA.backupNow();
    expect(schedulerA.lastVerifiedBackup, isNotNull);
    await schedulerA.stop();
    sessionA.useLocalOnly();

    final sessionB = AccountSessionController(
      apiClient,
      credentialStore: _MemoryAccountCredentialStore(),
    );
    await sessionB.login('account_b', 'b-secure-password');
    final serviceB = _RecordingRemoteBackupService(
      repository: repository,
      apiClient: apiClient,
      session: sessionB,
      deviceIds: deviceIds,
    );
    final schedulerB = RemoteBackupScheduler(
      service: serviceB,
      session: sessionB,
    );
    addTearDown(schedulerB.dispose);
    expect(schedulerB.lastVerifiedBackup, isNull);
    expect(schedulerB.lastError, isNull);
    schedulerB.enableForSignedInAccount();
    await schedulerB.backupNow();

    expect(deviceIds, hasLength(2));
    expect(deviceIds[0], isNot(deviceIds[1]));
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
    required this.deviceIds,
  });

  final List<String> deviceIds;

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

class _MemoryAccountCredentialStore implements AccountCredentialStore {
  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}
