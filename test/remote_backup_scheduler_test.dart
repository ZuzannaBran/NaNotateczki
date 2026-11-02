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
import 'package:program/data/sync/notebook_conflicts.dart';
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
    expect(RemoteBackupScheduler.defaultIdleSeconds, 30);
    expect(scheduler.idleSeconds, 30);
    await scheduler.setIdleSeconds(15);
    expect(scheduler.idleSeconds, 15);
    await scheduler.setIdleSeconds(60);
    expect(scheduler.idleSeconds, 60);
    await scheduler.setIdleSeconds(30);

    final schedulingWatch = Stopwatch()..start();
    for (var index = 0; index < 1000; index++) {
      scheduler.markDirty();
    }
    schedulingWatch.stop();
    debugPrint(
      'Backup scheduler 1000 changes: '
      '${schedulingWatch.elapsedMicroseconds} microseconds',
    );
    expect(schedulingWatch.elapsed, lessThan(const Duration(seconds: 1)));

    now = now.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));
    scheduler.markDirty();
    scheduler.recordUserInteraction();
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

  testWidgets('background changes and resume do not reset idle delay', (
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
      ..userId = 'background-account'
      ..username = 'background_account';
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
    await scheduler.setIdleSeconds(30);
    scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 40));
    scheduler.recordUserInteraction();
    scheduler.markDirty();
    scheduler.didChangeAppLifecycleState(AppLifecycleState.resumed);
    // Wait for the asynchronous upload, not just for its timer callback.
    // A backgrounded user interaction must not restart the idle clock.
    await scheduler.uploadNow();
    expect(service.calls, 1);

    await scheduler.stop();
    scheduler.dispose();
    session.dispose();
    client.close();
    await database.close();
  });

  testWidgets('normal account exit requires a verified remote snapshot', (
    tester,
  ) async {
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'exit-account';
    final service = _TrackingService(
      repository: NotebookRepository(database),
      apiClient: client,
      session: session,
    );
    final scheduler = RemoteBackupScheduler(service: service, session: session);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    scheduler.enableForSignedInAccount();
    expect(scheduler.hasPendingBackup, isTrue);

    await scheduler.ensureVerifiedForExit();
    expect(service.calls, 1);
    expect(scheduler.hasPendingBackup, isFalse);
    expect(scheduler.lastVerifiedBackup, isNotNull);

    scheduler.markDirty();
    service.failure = StateError('Network offline');
    await expectLater(scheduler.ensureVerifiedForExit(), throwsStateError);
    expect(scheduler.hasPendingBackup, isTrue);
    expect(scheduler.lastError, contains('Network offline'));

    await scheduler.stop();
    scheduler.dispose();
    session.dispose();
    client.close();
    await database.close();
  });

  testWidgets('remote import triggers backup without local user activity', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 2);
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    late final RemoteBackupScheduler scheduler;
    final repository = NotebookRepository(
      database,
      onChanged: (_) => scheduler.markDirty(),
    );
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'remote-import-account';
    final service = _TrackingService(
      repository: repository,
      apiClient: client,
      session: session,
    );
    scheduler = RemoteBackupScheduler(
      service: service,
      session: session,
      now: () => now,
    );
    final initial = await repository.createNotebook();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    scheduler.enableForSignedInAccount();
    var reconciliations = 0;
    scheduler.reconcileBeforeBackup = () async {
      reconciliations++;
    };
    // The first upload is user-forced; automatic uploads wait for idle time.
    await scheduler.backupNow();
    expect(scheduler.lastError, isNull);
    expect(service.calls, 1);
    expect(scheduler.hasPendingBackup, isFalse);

    final downloaded = numberedNotebookCopy(initial, [initial]);
    expect(downloaded.uid, isNot(initial.uid));
    expect(
      downloaded.pages.map((page) => page.id).toSet(),
      isNot(contains(initial.pages.first.id)),
    );
    await repository.importNotebooksAtomically([
      downloaded,
    ], verifiedRemoteSync: true);
    final imported = await repository.fetchNotebooks();
    expect(
      imported.map((notebook) => notebook.uid).toSet(),
      containsAll([initial.uid, downloaded.uid]),
    );
    expect(scheduler.hasPendingBackup, isTrue);
    // No new user input: the downloaded change must upload after 30 seconds.
    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(reconciliations, 2);
    expect(service.calls, 2);
    expect(scheduler.hasPendingBackup, isFalse);

    scheduler.markDirty();
    scheduler.reconcileBeforeBackup = () async {
      throw StateError('Unable to fetch latest account changes');
    };
    await scheduler.backupNow();
    expect(service.calls, 2);
    expect(scheduler.hasPendingBackup, isTrue);
    expect(scheduler.lastError, contains('Unable to fetch latest'));

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
    final scheduler = RemoteBackupScheduler(service: service, session: session);
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
  Object? failure;
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
    if (failure != null) {
      throw failure!;
    }
    return pending?.future ?? receipt;
  }
}
