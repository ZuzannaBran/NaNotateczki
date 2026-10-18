import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();

  testWidgets('safe insets and navigation adapt to phones and tablets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook(
      title: 'Responsive notes',
      folder: 'Projects A',
    );
    final library = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await library.loadItems();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 30, bottom: 24),
              viewPadding: const EdgeInsets.only(top: 30, bottom: 24),
            ),
            child: MultiProvider(
              providers: [
                ChangeNotifierProvider<LibraryController>.value(
                  value: library,
                ),
                Provider<NotebookRepository>.value(value: repository),
              ],
              child: const LibraryScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const menuKey = ValueKey('mobile-navigation-open');
    final menu = find.byKey(menuKey);
    expect(menu, findsOneWidget);
    expect(tester.getTopLeft(menu).dy, greaterThanOrEqualTo(30));

    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Projects'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('library-tree-item:${notebook.uid}')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsOneWidget);
    final editorBefore = tester
        .element(find.byType(EditorScreen))
        .read<EditorController>();
    final viewport = find.byKey(const ValueKey('notebook-page-viewport'));
    expect(tester.getSize(viewport).width, closeTo(366, 0.01));
    expect(find.byKey(menuKey), findsOneWidget);

    for (final size in <Size>[
      const Size(320, 680),
      const Size(768, 1024),
      const Size(844, 390),
      const Size(1024, 768),
      const Size(1440, 900),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      expect(
        tester
            .element(find.byType(EditorScreen))
            .read<EditorController>(),
        same(editorBefore),
      );
      if (size.width < 960) {
        expect(find.byKey(menuKey), findsOneWidget);
      } else {
        expect(find.byKey(menuKey), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
    await database.close();
  });
}
