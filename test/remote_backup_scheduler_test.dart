import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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

  setUp(() {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
  });

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  testWidgets('remote backup waits for adjustable user inactivity', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 1);
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-a'
      ..username = 'account_a';
    final service = _TrackingService(
      repository: NotebookRepository(database),
      apiClient: client,
      session: session,
    );
    final scheduler = RemoteBackupScheduler(
      service: service,
      session: session,
      now: () => now,
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    scheduler.enableForSignedInAccount();
    await tester.pump();
    await scheduler.setIdleSeconds(30);

    now = now.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));
    scheduler.markDirty();
    now = now.add(const Duration(seconds: 29));
    await tester.pump(const Duration(seconds: 29));
    expect(service.calls, 0);

    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(service.calls, 1);
    expect(scheduler.lastVerifiedBackup, isNotNull);

    await scheduler.stop();
    scheduler.dispose();
    session.dispose();
    client.close();
    await database.close();
  });

  testWidgets('upload pending on network does not block UI frames', (
    tester,
  ) async {
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-b'
      ..username = 'account_b';
    final service = _TrackingService(
      repository: NotebookRepository(database),
      apiClient: client,
      session: session,
    );
    service.pending = Completer<RemoteBackupReceipt>();
    final scheduler = RemoteBackupScheduler(
      service: service,
      session: session,
    );
    scheduler.enableForSignedInAccount();
    unawaited(scheduler.backupNow());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(service.calls, 1);
    expect(scheduler.isUploading, isTrue);
    service.pending!.complete(_TrackingService.receipt);
    await tester.pump();
    expect(scheduler.isUploading, isFalse);

    await scheduler.stop();
    scheduler.dispose();
    session.dispose();
    client.close();
    await database.close();
  });
}

class _TrackingService extends RemoteBackupService {
  _TrackingService({
    required super.repository,
    required super.apiClient,
    required super.session,
  });

  int calls = 0;
  Completer<RemoteBackupReceipt>? pending;
  static final receipt = RemoteBackupReceipt(
    backupId: 'backup-test',
    checksum: 'sha256',
    verifiedAt: DateTime.utc(2026, 11, 1),
  );

  @override
  Future<RemoteBackupReceipt> uploadVerifiedSnapshot({
    required String deviceId,
  }) async {
    calls++;
    return pending?.future ?? receipt;
  }
}
