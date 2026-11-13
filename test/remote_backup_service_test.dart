import 'dart:convert';

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

  test(
    'v2 scheduler uses verified operational API, never legacy backup',
    () async {
      final values = <String, String>{};
      textStorageReadOverride = (key) async => values[key];
      textStorageWriteOverride = (key, value) async => values[key] = value;
      final api = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          fail('The v2 backup callback must not access legacy transport.');
        }),
      );
      addTearDown(api.close);
      final session = AccountSessionController(api)
        ..mode = AccountDataMode.account
        ..userId = 'user-1';
      addTearDown(session.dispose);
      final scheduler = RemoteBackupScheduler(session: session);
      addTearDown(scheduler.dispose);
      final operationalCalls = <String>[];
      scheduler.uploadOperationalSnapshot = (deviceId) async {
        operationalCalls.add(deviceId);
        return RemoteBackupReceipt(
          backupId: 'operational-1',
          checksum: 'sha-v2',
          verifiedAt: DateTime.utc(2026, 11, 12),
        );
      };
      scheduler.enableForSignedInAccount();
      await scheduler.backupNow();
      expect(scheduler.lastVerifiedBackup?.backupId, 'operational-1');
      expect(operationalCalls, hasLength(1));
      scheduler.uploadOperationalSnapshot = null;
      await scheduler.backupNow();
      expect(operationalCalls, hasLength(1));
      expect(scheduler.lastError, contains('V2 backup is unavailable'));
    },
  );

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
    final schedulerA = RemoteBackupScheduler(session: sessionA);
    addTearDown(schedulerA.dispose);

    schedulerA.uploadOperationalSnapshot = (id) =>
        serviceA.uploadVerifiedSnapshot(deviceId: id);
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
    final schedulerB = RemoteBackupScheduler(session: sessionB);
    addTearDown(schedulerB.dispose);
    expect(schedulerB.lastVerifiedBackup, isNull);
    expect(schedulerB.lastError, isNull);
    schedulerB.uploadOperationalSnapshot = (id) =>
        serviceB.uploadVerifiedSnapshot(deviceId: id);
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
