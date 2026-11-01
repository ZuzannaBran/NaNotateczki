import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/backup/remote_backup_scheduler.dart';
import 'package:program/data/backup/remote_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/data/sync/live_web_sync_service.dart';
import 'package:program/features/library/presentation/library_account_slot.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();

  setUp(() {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
  });

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  testWidgets(
    'account is available on desktop and mobile with safe first sync',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final apiClient = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((_) async => http.Response('', 500)),
      );
      final database = NotesDatabase(NativeDatabase.memory());
      final repository = NotebookRepository(database);
      final library = LibraryController(
        repository,
        CloudSyncService(repository),
        LocalBackupService(repository),
      );
      final session = _FakeAccountSessionController(apiClient);
      final remoteBackupService = _FakeRemoteBackupService(
        repository: repository,
        apiClient: apiClient,
        session: session,
      );
      final backup = RemoteBackupScheduler(
        service: remoteBackupService,
        session: session,
      );
      final sync = _FakeLiveWebSyncService(
        repository: repository,
        apiClient: apiClient,
        session: session,
      );
      var stoppedBeforeSessionClear = false;
      session.addListener(() {
        if (!session.isSignedIn) {
          stoppedBeforeSessionClear = !sync.isStarted && !backup.isEnabled;
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<LibraryController>.value(value: library),
              Provider<NotebookRepository>.value(value: repository),
              ChangeNotifierProvider<AccountSessionController>.value(
                value: session,
              ),
              ChangeNotifierProvider<RemoteBackupScheduler>.value(
                value: backup,
              ),
              ChangeNotifierProvider<LiveWebSyncService>.value(value: sync),
            ],
            child: const LibraryScreen(liveSyncAvailable: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('account-menu-button')), findsOneWidget);

      await tester.binding.setSurfaceSize(const Size(500, 800));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-navigation-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-menu-button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('account-settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-sign-in-choice')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(
          find.byKey(const ValueKey('account-password')),
        ).obscureText,
        isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey('account-password-visibility-Password')),
      );
      await tester.pump();
      expect(
        tester.widget<TextFormField>(
          find.byKey(const ValueKey('account-password')),
        ).obscureText,
        isFalse,
      );
      await tester.tap(
        find.byKey(const ValueKey('account-password-visibility-Password')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('account-email')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password')),
        'a-secure-password',
      );
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('account-login-submit')),
          )
          .onPressed!();
      for (var i = 0; i < 100 && !session.isSignedIn; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();

      expect(session.isSignedIn, isTrue);
      expect(backup.isEnabled, isTrue);
      expect(find.byKey(const ValueKey('sync-policy-upload')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sync-policy-download')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('sync-policy-merge')), findsOneWidget);

      tester
          .widget<OutlinedButton>(
            find.descendant(
              of: find.byKey(const ValueKey('sync-policy-merge')),
              matching: find.byType(OutlinedButton),
            ),
          )
          .onPressed!();
      for (var i = 0; i < 100 && !sync.isStarted; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(sync.isStarted, isTrue);
      expect(sync.selectedPolicy, InitialSyncPolicy.mergeSafely);
      expect(find.byKey(const ValueKey('live-sync-status')), findsOneWidget);

      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('account-backup-now')),
          )
          .onPressed!();
      for (var i = 0; i < 100 && remoteBackupService.calls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(remoteBackupService.calls, 1);
      expect(find.text('Backup verified.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('account-switch-local')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-local-name')),
        'Local Zuzanna',
      );
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('account-local-submit')),
          )
          .onPressed!();
      for (var i = 0; i < 100 && session.isSignedIn; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();

      expect(session.isLocalProfile, isTrue);
      expect(session.displayName, 'Local Zuzanna');
      expect(sync.isStarted, isFalse);
      expect(backup.isEnabled, isFalse);
      expect(stoppedBeforeSessionClear, isTrue);

      await tester.tap(find.byKey(const ValueKey('account-switch-online')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-sign-in-choice')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-email')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password')),
        'a-secure-password',
      );
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('account-login-submit')),
          )
          .onPressed!();
      for (var i = 0; i < 100 && !session.isSignedIn; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();

      expect(session.isSignedIn, isTrue);
      expect(backup.isEnabled, isTrue);
      tester
          .widget<OutlinedButton>(
            find.descendant(
              of: find.byKey(const ValueKey('sync-policy-merge')),
              matching: find.byType(OutlinedButton),
            ),
          )
          .onPressed!();
      for (var i = 0; i < 100 && !sync.isStarted; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(sync.isStarted, isTrue);

      await tester.tap(find.byKey(const ValueKey('account-change-password')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-current-password')),
        'current-secure-password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-new-password')),
        'new-secure-password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-new-password-confirmation')),
        'different-password',
      );
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('account-change-password-submit')),
          )
          .onPressed!();
      await tester.pump();
      expect(find.text('Passwords do not match.'), findsOneWidget);
      expect(session.changedPassword, isFalse);

      await tester.enterText(
        find.byKey(const ValueKey('account-new-password-confirmation')),
        'new-secure-password',
      );
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('account-change-password-submit')),
          )
          .onPressed!();
      for (var i = 0; i < 100 && session.isSignedIn; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();

      expect(session.isSignedIn, isFalse);
      expect(session.changedPassword, isTrue);
      expect(session.currentPassword, 'current-secure-password');
      expect(session.newPassword, 'new-secure-password');
      expect(sync.isStarted, isFalse);
      expect(backup.isEnabled, isFalse);
      expect(stoppedBeforeSessionClear, isTrue);
      expect(find.text('Password changed. Sign in again.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      sync.dispose();
      backup.dispose();
      session.dispose();
      library.dispose();
      apiClient.close();
      await database.close();
    },
  );

  testWidgets('account slot stays empty when account providers are absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LibraryAccountSlot(liveSyncAvailable: true)),
    );

    expect(find.byKey(const ValueKey('account-menu-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first launch offers registration and creates a local profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final apiClient = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final library = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    final session = AccountSessionController(apiClient);
    session.profileLoaded = true;
    final backup = RemoteBackupScheduler(
      service: _FakeRemoteBackupService(
        repository: repository,
        apiClient: apiClient,
        session: session,
      ),
      session: session,
    );
    final sync = _FakeLiveWebSyncService(
      repository: repository,
      apiClient: apiClient,
      session: session,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryController>.value(value: library),
            Provider<NotebookRepository>.value(value: repository),
            ChangeNotifierProvider<AccountSessionController>.value(
              value: session,
            ),
            ChangeNotifierProvider<RemoteBackupScheduler>.value(value: backup),
            ChangeNotifierProvider<LiveWebSyncService>.value(value: sync),
          ],
          child: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('NaNotateczki'), findsOneWidget);
    final welcomeCopy = tester.widget<Text>(
      find.byKey(const ValueKey('account-welcome-description')),
    );
    expect(welcomeCopy.textAlign, TextAlign.center);
    expect(welcomeCopy.data, contains('NaNotateczki'));
    expect(find.byKey(const ValueKey('account-create-choice')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('account-sign-in-choice')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('account-local-choice')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-create-choice')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('account-email')),
      'user@example.com',
    );
    expect(find.text('Username'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('account-password')),
      '1234567',
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-password-confirmation')),
      '1234567',
    );
    tester
        .widget<FilledButton>(
          find.byKey(const ValueKey('account-register-submit')),
        )
        .onPressed!();
    await tester.pump();
    expect(find.text('Use 8 to 128 characters.'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('account-password')),
      'first-secure-password',
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-password-confirmation')),
      'different-password',
    );
    tester
        .widget<FilledButton>(
          find.byKey(const ValueKey('account-register-submit')),
        )
        .onPressed!();
    await tester.pump();
    expect(find.text('Passwords do not match.'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('account-local-choice')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('account-local-name')),
      'Zuzanna',
    );
    tester
        .widget<FilledButton>(
          find.byKey(const ValueKey('account-local-submit')),
        )
        .onPressed!();
    for (var i = 0; i < 100 && !session.isLocalProfile; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();

    expect(find.text('Welcome'), findsNothing);
    expect(find.text('Zuzanna'), findsOneWidget);
    expect(find.text('Z'), findsOneWidget);
    final sidebarAvatar = find.byKey(const ValueKey('account-avatar'));
    final sidebarDecoration =
        tester.widget<Container>(sidebarAvatar).decoration! as BoxDecoration;
    expect(sidebarDecoration.shape, BoxShape.circle);
    expect(sidebarDecoration.border, isNotNull);
    expect(tester.getSize(sidebarAvatar), const Size(32, 32));

    final settingsIcon = find.descendant(
      of: find.byKey(const ValueKey('account-settings-button')),
      matching: find.byIcon(Icons.settings_outlined),
    );
    expect(tester.widget<Icon>(settingsIcon).size, 18);

    await tester.tap(find.byKey(const ValueKey('account-settings-button')));
    await tester.pumpAndSettle();
    final dialogAvatar = find.byKey(const ValueKey('account-dialog-avatar'));
    final dialogDecoration =
        tester.widget<Container>(dialogAvatar).decoration! as BoxDecoration;
    expect(dialogDecoration.shape, BoxShape.circle);
    expect(dialogDecoration.border, isNotNull);
    expect(tester.getSize(dialogAvatar), const Size(40, 40));
    expect(find.byKey(const ValueKey('account-remote-status')), findsNothing);
    expect(
      find.byKey(const ValueKey('account-settings-button')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    sync.dispose();
    backup.dispose();
    session.dispose();
    library.dispose();
    apiClient.close();
    await database.close();
  });
}

class _FakeAccountSessionController extends AccountSessionController {
  _FakeAccountSessionController(super.apiClient);

  bool changedPassword = false;
  String? currentPassword;
  String? newPassword;

  @override
  Future<void> login(String rawEmail, String password) async {
    mode = AccountDataMode.account;
    preferredMode = AccountDataMode.account;
    onboardingComplete = true;
    userId = 'user-1';
    email = rawEmail.trim().toLowerCase();
    apiClient.setAccessToken('access');
    notifyListeners();
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    changedPassword = true;
    this.currentPassword = currentPassword;
    this.newPassword = newPassword;
  }

  @override
  Future<void> logout() async {
    useLocalOnly();
  }
}

class _FakeRemoteBackupService extends RemoteBackupService {
  _FakeRemoteBackupService({
    required super.repository,
    required super.apiClient,
    required super.session,
  });

  int calls = 0;

  @override
  Future<RemoteBackupReceipt> uploadVerifiedSnapshot({
    required String deviceId,
  }) async {
    calls++;
    return RemoteBackupReceipt(
      backupId: 'backup-$calls',
      checksum: 'checksum-$calls',
      verifiedAt: DateTime.now().toUtc(),
    );
  }
}

class _FakeLiveWebSyncService extends LiveWebSyncService {
  _FakeLiveWebSyncService({
    required super.repository,
    required super.apiClient,
    required super.session,
  });

  bool _startedForTest = false;
  InitialSyncPolicy? selectedPolicy;

  @override
  bool get isStarted => _startedForTest;

  @override
  bool get hasPendingChanges => false;

  @override
  Future<void> start(InitialSyncPolicy policy) async {
    selectedPolicy = policy;
    _startedForTest = true;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _startedForTest = false;
    notifyListeners();
  }
}
