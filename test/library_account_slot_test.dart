import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:program/core/storage/app_save_coordinator.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/core/theme/app_typography.dart';
import 'package:program/core/widgets/app_header_divider.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/backup/remote_backup_scheduler.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_credential_store.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
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

  testWidgets('account slot stays empty when account providers are absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LibraryAccountSlot(liveSyncAvailable: true)),
    );

    expect(find.byKey(const ValueKey('account-menu-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logout drains local saves after the dialog is unmounted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final apiClient = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = _PendingSaveRepository(database);
    final session =
        AccountSessionController(
            apiClient,
            credentialStore: _MemoryAccountCredentialStore(),
          )
          ..mode = AccountDataMode.account
          ..userId = 'test-user'
          ..username = 'test_user'
          ..profileLoaded = true
          ..onboardingComplete = true;
    final backup = RemoteBackupScheduler(session: session);
    final editorFlush = Completer<void>();
    var editorFlushStarted = false;
    final owner = Object();
    AppSaveCoordinator.instance.register(
      owner,
      hasPendingWork: () => !editorFlush.isCompleted,
      flush: () {
        editorFlushStarted = true;
        return editorFlush.future;
      },
    );
    addTearDown(() async {
      if (!editorFlush.isCompleted) {
        editorFlush.complete();
      }
      if (!repository.savesCompleted.isCompleted) {
        repository.savesCompleted.complete();
      }
      AppSaveCoordinator.instance.unregister(owner);
      backup.dispose();
      session.dispose();
      apiClient.close();
      await database.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            Provider<NotebookRepository>.value(value: repository),
            ChangeNotifierProvider<AccountSessionController>.value(
              value: session,
            ),
            ChangeNotifierProvider<RemoteBackupScheduler>.value(value: backup),
          ],
          child: const Scaffold(body: LibraryAccountSlot()),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('account-settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('account-logout')));
    await tester.pump();
    expect(editorFlushStarted, isTrue);
    expect(repository.waitStarted.isCompleted, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    editorFlush.complete();
    await tester.pump();
    expect(repository.waitStarted.isCompleted, isTrue);
    expect(session.isSignedIn, isTrue);

    repository.savesCompleted.complete();
    await tester.pump();
    expect(session.isSignedIn, isTrue);
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
      LocalBackupService(repository),
    );
    final session = AccountSessionController(
      apiClient,
      credentialStore: _MemoryAccountCredentialStore(),
    );
    session.profileLoaded = true;
    final backup = RemoteBackupScheduler(session: session);

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
    backup.dispose();
    session.dispose();
    library.dispose();
    apiClient.close();
    await database.close();
  });
}

class _PendingSaveRepository extends NotebookRepository {
  _PendingSaveRepository(super.database);

  final waitStarted = Completer<void>();
  final savesCompleted = Completer<void>();

  @override
  bool get hasPendingSaves => !savesCompleted.isCompleted;

  @override
  Future<void> waitForPendingSaves() async {
    waitStarted.complete();
    await savesCompleted.future;
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
