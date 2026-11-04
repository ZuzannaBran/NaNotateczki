import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:program/core/storage/text_storage.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/core/theme/app_typography.dart';
import 'package:program/core/widgets/app_header_divider.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/backup/remote_backup_scheduler.dart';
import 'package:program/data/backup/remote_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_credential_store.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/data/sync/live_web_sync_service.dart';
import 'package:program/features/library/presentation/library_account_slot.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

import 'support/native_test_documents.dart';

void _expectAccountActionSpacing(
  WidgetTester tester,
  Finder first,
  Finder second,
) {
  expect(first, findsOneWidget);
  expect(second, findsOneWidget);
  final gap = tester.getRect(second).top - tester.getRect(first).bottom;
  expect(gap, greaterThanOrEqualTo(12));
}

void _expectAccountFieldLayout(
  WidgetTester tester,
  String fieldKey,
  String label,
) {
  final input = find.byKey(ValueKey(fieldKey));
  final caption = find.byKey(ValueKey('account-field-label-$label'));

  expect(input, findsOneWidget);
  expect(caption, findsOneWidget);
  expect(tester.getRect(caption).bottom, lessThan(tester.getRect(input).top));

  final text = tester.widget<Text>(caption);
  expect(text.style?.fontSize, AppTypography.document);
  expect(text.style?.fontWeight, FontWeight.w600);

  final textField = find.descendant(
    of: input,
    matching: find.byType(TextField),
  );
  final decoration = tester.widget<TextField>(textField).decoration!;
  expect(decoration.labelText, isNull);
  expect(decoration.floatingLabelBehavior, FloatingLabelBehavior.never);
  expect(decoration.filled, isNot(true));
  expect(
    (decoration.border! as OutlineInputBorder).borderRadius,
    BorderRadius.circular(12),
  );
}

void _expectAccountHeaderTypography(WidgetTester tester) {
  final title = tester.widget<Text>(
    find.byKey(const ValueKey('account-display-name')),
  );
  expect(title.style?.fontSize, AppTypography.document);
  expect(title.style?.fontWeight, FontWeight.w400);

  final statusFinder = find.byKey(const ValueKey('account-status'));
  expect(statusFinder, findsOneWidget);
  final status = tester.widget<Text>(statusFinder);
  expect(status.style?.fontSize, AppTypography.small);
  expect(
    status.style?.color,
    Theme.of(tester.element(statusFinder)).colorScheme.onSurfaceVariant,
  );

  final footer = find.byKey(const ValueKey('account-menu-button'));
  expect(find.byKey(const ValueKey('account-avatar')), findsNothing);
  expect(
    tester.getTopLeft(find.byKey(const ValueKey('account-display-name'))).dx,
    closeTo(tester.getTopLeft(footer).dx + 14, 0.1),
  );
  expect(
    tester.getTopLeft(statusFinder).dx,
    tester.getTopLeft(find.byKey(const ValueKey('account-display-name'))).dx,
  );
}

void _expectAccountDialogTypography(WidgetTester tester) {
  final heading = tester.widget<Text>(
    find.byKey(const ValueKey('account-dialog-title')),
  );
  expect(heading.style, AppHeaderDivider.titleStyle);
}

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

  test('account and timer share application typography in both modes', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      expect(theme.textTheme.titleLarge?.fontFamily, AppTypography.fontFamily);
      expect(theme.textTheme.bodyMedium?.fontFamily, AppTypography.fontFamily);
      expect(theme.textTheme.bodySmall?.fontFamily, AppTypography.fontFamily);
      expect(AppHeaderDivider.titleStyle.fontSize, AppTypography.heading);
      expect(AppHeaderDivider.titleStyle.fontWeight, FontWeight.w600);
    }
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
            child: const LibraryScreen(),
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
      _expectAccountDialogTypography(tester);
      await tester.tap(find.byKey(const ValueKey('account-sign-in-choice')));
      await tester.pumpAndSettle();
      _expectAccountActionSpacing(
        tester,
        find.byKey(const ValueKey('account-login-submit')),
        find.widgetWithText(TextButton, 'Back'),
      );
      _expectAccountFieldLayout(tester, 'account-username', 'Username');
      _expectAccountFieldLayout(tester, 'account-password', 'Password');
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const ValueKey('account-password')),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey('account-password-visibility-Password')),
      );
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const ValueKey('account-password')),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isFalse,
      );
      await tester.tap(
        find.byKey(const ValueKey('account-password-visibility-Password')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('account-username')),
        'test_user',
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
      // AppScope enables backups only after recovering remote account data.
      expect(backup.isEnabled, isFalse);
      backup.enableForSignedInAccount();
      await tester.pump();
      final idleOptions = tester
          .widget<DropdownButton<int>>(
            find.byKey(const ValueKey('account-backup-idle')),
          )
          .items!
          .map((item) => item.value);
      expect(idleOptions, containsAll([30, 60, 120, 300, 900, 1800]));
      _expectAccountHeaderTypography(tester);
      _expectAccountDialogTypography(tester);
      final profileName = tester.widget<Text>(
        find.byKey(const ValueKey('account-dialog-display-name')),
      );
      expect(profileName.style, AppHeaderDivider.titleStyle);
      final profileMode = tester.widget<Text>(
        find.byKey(const ValueKey('account-dialog-mode')),
      );
      expect(profileMode.style?.fontSize, AppTypography.small);
      _expectAccountActionSpacing(
        tester,
        find.byKey(const ValueKey('account-change-password')),
        find.byKey(const ValueKey('account-switch-local')),
      );
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
      _expectAccountActionSpacing(
        tester,
        find.byKey(const ValueKey('account-local-submit')),
        find.widgetWithText(TextButton, 'Back'),
      );
      _expectAccountFieldLayout(tester, 'account-local-name', 'Your name');
      await tester.enterText(
        find.byKey(const ValueKey('account-local-name')),
        'Local Zuzanna',
      );
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('account-local-submit')),
          )
          .onPressed!();
      for (var i = 0; i < 100 && !session.isLocalProfile; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();

      expect(session.isLocalProfile, isTrue);
      expect(session.displayName, 'Local Zuzanna');
      _expectAccountHeaderTypography(tester);
      _expectAccountDialogTypography(tester);
      expect(sync.isStarted, isFalse);
      expect(backup.isEnabled, isFalse);
      expect(stoppedBeforeSessionClear, isTrue);

      await tester.tap(find.byKey(const ValueKey('account-switch-online')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-sign-in-choice')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-username')),
        'test_user',
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
      expect(backup.isEnabled, isFalse);
      backup.enableForSignedInAccount();
      await tester.pump();
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
      expect(find.byKey(const ValueKey('account-logout')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('account-backup-now')),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );

      final uploadsBeforeLogout = remoteBackupService.calls;
      remoteBackupService.failNextUpload = true;
      await tester.tap(find.byKey(const ValueKey('account-logout')));
      for (
        var i = 0;
        i < 100 && find.text('Account sync not complete').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('Account sync not complete'), findsOneWidget);
      expect(session.isSignedIn, isTrue);
      expect(remoteBackupService.calls, uploadsBeforeLogout + 1);
      expect(sync.isStarted, isTrue);
      // An incomplete backup requires an explicit decision; it must not
      // silently log out or leave a spinning progress indicator.
      await tester.tap(find.text('Stay signed in'));
      await tester.pumpAndSettle();
      expect(find.text('Account sync not complete'), findsNothing);
      expect(find.byKey(const ValueKey('account-logout')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('account-logout')));
      for (var i = 0; i < 100 && session.isSignedIn; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pumpAndSettle();
      expect(session.isSignedIn, isFalse);
      expect(remoteBackupService.calls, uploadsBeforeLogout + 2);
      expect(sync.isStarted, isFalse);
      expect(backup.isEnabled, isFalse);
      expect(
        find.byKey(const ValueKey('account-sign-in-choice')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('account-sign-in-choice')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-username')),
        'test_user',
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

      await tester.ensureVisible(
        find.byKey(const ValueKey('account-change-password')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-change-password')));
      await tester.pumpAndSettle();
      _expectAccountActionSpacing(
        tester,
        find.byKey(const ValueKey('account-change-password-submit')),
        find.widgetWithText(TextButton, 'Back'),
      );
      _expectAccountFieldLayout(
        tester,
        'account-current-password',
        'Current password',
      );
      _expectAccountFieldLayout(tester, 'account-new-password', 'New password');
      _expectAccountFieldLayout(
        tester,
        'account-new-password-confirmation',
        'Repeat new password',
      );
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
    final session = AccountSessionController(
      apiClient,
      credentialStore: _MemoryAccountCredentialStore(),
    );
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
    await tester.pump();

    expect(find.text('Welcome'), findsNothing);
    _expectAccountDialogTypography(tester);
    expect(find.text('NaNotateczki'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('account-dialog-title')))
          .style,
      AppHeaderDivider.titleStyle,
    );
    final welcomeCopy = tester.widget<Text>(
      find.byKey(const ValueKey('account-welcome-description')),
    );
    expect(welcomeCopy.textAlign, TextAlign.center);
    expect(welcomeCopy.data, contains('NaNotateczki'));
    expect(welcomeCopy.data, startsWith('Welcome.'));
    expect(welcomeCopy.style?.fontSize, AppTypography.document);
    expect(find.byKey(const ValueKey('account-create-choice')), findsOneWidget);
    _expectAccountActionSpacing(
      tester,
      find.byKey(const ValueKey('account-create-choice')),
      find.byKey(const ValueKey('account-sign-in-choice')),
    );
    expect(
      find.byKey(const ValueKey('account-sign-in-choice')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('account-local-choice')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-create-choice')));
    await tester.pumpAndSettle();
    _expectAccountActionSpacing(
      tester,
      find.byKey(const ValueKey('account-register-submit')),
      find.widgetWithText(TextButton, 'Back'),
    );
    _expectAccountFieldLayout(tester, 'account-username', 'Username');
    _expectAccountFieldLayout(tester, 'account-password', 'Password');
    _expectAccountFieldLayout(
      tester,
      'account-password-confirmation',
      'Repeat password',
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-username')),
      'test_user',
    );
    expect(find.text('Username'), findsOneWidget);
    _expectAccountFieldLayout(tester, 'account-username', 'Username');
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
    _expectAccountActionSpacing(
      tester,
      find.byKey(const ValueKey('account-local-submit')),
      find.widgetWithText(TextButton, 'Back'),
    );
    _expectAccountFieldLayout(tester, 'account-local-name', 'Your name');
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
    _expectAccountHeaderTypography(tester);
    expect(find.text('Z'), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('account-status'))).data,
      'Local mode',
    );

    final settingsIcon = find.descendant(
      of: find.byKey(const ValueKey('account-settings-button')),
      matching: find.byIcon(Icons.settings_outlined),
    );
    expect(tester.widget<Icon>(settingsIcon).size, 18);

    await tester.tap(find.byKey(const ValueKey('account-settings-button')));
    await tester.pumpAndSettle();
    _expectAccountDialogTypography(tester);
    final dialogAvatar = find.byKey(const ValueKey('account-dialog-avatar'));
    final dialogAvatarContainer = find.descendant(
      of: dialogAvatar,
      matching: find.byType(Container),
    );
    final dialogDecoration =
        tester.widget<Container>(dialogAvatarContainer).decoration!
            as BoxDecoration;
    expect(dialogDecoration.shape, BoxShape.circle);
    expect(dialogDecoration.border, isNotNull);
    expect(tester.getSize(dialogAvatar), const Size(40, 40));
    _expectAccountActionSpacing(
      tester,
      find.byKey(const ValueKey('account-edit-local-name')),
      find.byKey(const ValueKey('account-switch-online')),
    );
    expect(find.byKey(const ValueKey('account-status')), findsOneWidget);
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
  _FakeAccountSessionController(super.apiClient)
    : super(credentialStore: _MemoryAccountCredentialStore());

  bool changedPassword = false;
  String? currentPassword;
  String? newPassword;

  @override
  Future<void> login(String rawUsername, String password) async {
    mode = AccountDataMode.account;
    preferredMode = AccountDataMode.account;
    onboardingComplete = true;
    userId = 'user-1';
    username = rawUsername.trim().toLowerCase();
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

class _MemoryAccountCredentialStore implements AccountCredentialStore {
  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

class _FakeRemoteBackupService extends RemoteBackupService {
  _FakeRemoteBackupService({
    required super.repository,
    required super.apiClient,
    required super.session,
  });

  int calls = 0;
  bool failNextUpload = false;

  @override
  Future<RemoteBackupReceipt> uploadVerifiedSnapshot({
    required String deviceId,
  }) async {
    calls++;
    if (failNextUpload) {
      failNextUpload = false;
      throw StateError('Simulated backup failure');
    }
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
