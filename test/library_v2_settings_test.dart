import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/data/sync/editor_v2_account_runtime.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/features/editor/presentation/editor_settings_screen.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/presentation/notebook_screen.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  testWidgets('v2 catalog keeps editor settings without a legacy writer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final api = ApiClient(
      httpClient: MockClient((_) async {
        throw StateError('Local settings must not access the network.');
      }),
    );
    final runtime = EditorV2AccountRuntime(
      repository: repository,
      apiClient: api,
      accountId: 'settings-account',
      actorId: 'settings-actor',
    );
    await repository.enableAccountOperations(runtime.writer);
    final notebook = await repository.createNotebook();
    final library = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await library.loadItems();
    final preferences = AppPreferencesController();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryController>.value(value: library),
          ChangeNotifierProvider<AppPreferencesController>.value(
            value: preferences,
          ),
          Provider<NotebookRepository>.value(value: repository),
          Provider<EditorV2AccountRuntime?>.value(value: runtime),
          Provider<ApiClient>.value(value: api),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final initialOperations = await runtime.store.pending(
      includeDeferred: true,
    );

    for (var opening = 0; opening < 2; opening++) {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Stylus and touch'), findsOneWidget);
      final editor = tester
          .element(find.byType(EditorSettingsScreen))
          .read<EditorController>();
      expect(editor.operationWriter, same(runtime.writer));
      expect(editor.notebook.uid, notebook.uid);
      await expectLater(
        repository.saveNotebook(editor.notebook),
        throwsStateError,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    expect(
      await runtime.store.pending(includeDeferred: true),
      hasLength(initialOperations.length),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    preferences.dispose();
    library.dispose();
    runtime.dispose();
    api.close();
    await database.close();
  });

  testWidgets('v2 library opens the real editor with its journal writer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final api = ApiClient(
      httpClient: MockClient((_) async {
        throw StateError('Local editor must not require an online API.');
      }),
    );
    final runtime = EditorV2AccountRuntime(
      repository: repository,
      apiClient: api,
      accountId: 'editor-account',
      actorId: 'editor-actor',
    );
    await repository.enableAccountOperations(runtime.writer);
    final notebook = await repository.createNotebook(title: 'Real v2 editor');
    final library = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await library.loadItems();
    final preferences = AppPreferencesController();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryController>.value(value: library),
          ChangeNotifierProvider<AppPreferencesController>.value(
            value: preferences,
          ),
          Provider<NotebookRepository>.value(value: repository),
          Provider<EditorV2AccountRuntime?>.value(value: runtime),
          Provider<ApiClient>.value(value: api),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('catalog-folder-grid')),
        matching: find.text('Notes'),
      ).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('catalog-document-grid')),
        matching: find.text('Real v2 editor'),
      ).first,
    );
    await tester.pumpAndSettle();
    final editor = tester
        .element(find.byType(NotebookScreen))
        .read<EditorController>();
    expect(editor.operationWriter, same(runtime.writer));
    final initial = await runtime.store.pending(includeDeferred: true);
    editor.addInkStroke(const [InkPoint(dx: 8, dy: 12, pressure: 0.6)]);
    await editor.flushPendingSaves();
    final pending = await runtime.store.pending(includeDeferred: true);
    expect(pending, hasLength(initial.length + 1));
    expect(pending.last.kind, OperationKind.strokeCreate);
    expect(
      (await repository.getNotebook(notebook.uid))!.pages.single.inkStrokes,
      hasLength(1),
    );
    await expectLater(
      repository.saveNotebook(editor.notebook),
      throwsStateError,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    preferences.dispose();
    library.dispose();
    runtime.dispose();
    api.close();
    await database.close();
  });
}
