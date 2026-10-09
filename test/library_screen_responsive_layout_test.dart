import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/editor/presentation/widgets/editor_toolbar.dart';
import 'package:program/features/editor/presentation/widgets/text_edit_toolbar.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/text_block.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

void main() {
  testWidgets('library locks wide layout below editor margin breakpoint', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1038, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryController>.value(value: controller),
            Provider<NotebookRepository>.value(value: repository),
          ],
          child: const LibraryScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Pick an item'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(1037, 700));
    await tester.pump();

    expect(find.text('Pick an item'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('library tree expands and collapses each folder', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final created = await repository.createNotebook(folder: 'Project A');
    await repository.updateNotebookMetadata(created.uid, title: 'Nested note');
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await controller.loadItems();

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryController>.value(value: controller),
            Provider<NotebookRepository>.value(value: repository),
          ],
          child: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final treeItem = find.byKey(ValueKey('library-tree-item:${created.uid}'));

    expect(find.text('Project A'), findsOneWidget);
    expect(treeItem, findsOneWidget);
    expect(
      find.descendant(of: treeItem, matching: find.text('Nested note')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Collapse Project A'));
    await tester.pumpAndSettle();

    expect(treeItem, findsNothing);
    expect(find.byTooltip('Expand Project A'), findsOneWidget);

    await tester.tap(find.byTooltip('Expand Project A'));
    await tester.pumpAndSettle();

    expect(treeItem, findsOneWidget);
    expect(
      find.descendant(of: treeItem, matching: find.text('Nested note')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('toolbar toggle hides tools on board and notebook', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final board = await repository.createBoard();
    final notebook = await repository.createNotebook();
    final preferences = AppPreferencesController();
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await controller.loadItems();
    await controller.selectItem(board.uid);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryController>.value(value: controller),
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            Provider<NotebookRepository>.value(value: repository),
          ],
          child: const LibraryScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Projects'), findsOneWidget);
    expect(find.byType(EditorToolbar), findsOneWidget);
    final panel = tester.widget<Container>(
      find.byKey(const ValueKey('editor-toolbar-panel')),
    );
    expect(
      (panel.decoration as BoxDecoration).borderRadius,
      BorderRadius.circular(999),
    );
    final navigationToggle = find.byKey(
      const ValueKey('library-navigation-toggle'),
    );
    final toolbarToggle = find.byKey(const ValueKey('editor-toolbar-toggle'));
    expect(
      tester.getTopLeft(toolbarToggle).dy,
      greaterThan(tester.getBottomLeft(navigationToggle).dy),
    );

    await tester.tap(find.byTooltip('Hide projects'));
    await tester.pump();
    expect(find.byTooltip('Show projects'), findsOneWidget);
    expect(find.byTooltip('Hide toolbar'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide toolbar'));
    await tester.pump();
    expect(find.byType(EditorToolbar), findsNothing);
    expect(find.byTooltip('Show toolbar'), findsOneWidget);

    await controller.selectItem(notebook.uid);
    await tester.pump();
    expect(find.byType(EditorToolbar), findsNothing);

    await tester.tap(find.byTooltip('Show toolbar'));
    await tester.pump();
    expect(find.byType(EditorToolbar), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await database.close();
  });

  testWidgets('toolbars shrink to content, center and scroll when narrow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 750));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final controller = EditorController(
      repository: repository,
      notebook: notebook,
    );
    final block = TextBlock(
      id: 'test-text',
      text: 'Hello',
      position: Offset.zero,
      fontSize: 18,
      color: Colors.black,
      width: 200,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              EditorToolbar(
                controller: controller,
                onInsertPressed: () {},
                onExportSelected: (_) {},
              ),
              TextEditToolbar(editorController: controller, block: block),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final mainPanel = find.byKey(const ValueKey('editor-toolbar-panel'));
    final textPanel = find.byKey(const ValueKey('text-toolbar-panel'));
    for (final panel in [mainPanel, textPanel]) {
      final rect = tester.getRect(panel);
      expect(rect.width, lessThan(1600 - 88));
      expect(rect.center.dx, closeTo(800, 0.01));
      expect(
        (tester.widget<Container>(panel).decoration as BoxDecoration)
            .borderRadius,
        BorderRadius.circular(999),
      );
    }

    await tester.binding.setSurfaceSize(const Size(560, 750));
    await tester.pump();

    for (final panel in [mainPanel, textPanel]) {
      final rect = tester.getRect(panel);
      expect(rect.width, closeTo(560 - 88, 0.01));
      expect(rect.center.dx, closeTo(280, 0.01));
      final scroller = find.descendant(
        of: panel,
        matching: find.byType(Scrollable),
      );
      expect(scroller, findsOneWidget);
      expect(
        tester.state<ScrollableState>(scroller).position.maxScrollExtent,
        greaterThan(0),
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('study timer is anchored to the bottom of the folder sidebar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    final planner = StudyPlannerController(
      autoTick: false,
      read: (_) async => null,
      write: (_, _) async {},
    );
    await planner.load();
    await controller.loadItems();

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryController>.value(value: controller),
            ChangeNotifierProvider<StudyPlannerController>.value(value: planner),
            Provider<NotebookRepository>.value(value: repository),
          ],
          child: const LibraryScreen(),
        ),
      ),
    );
    await tester.pump();

    final timer = find.byKey(const ValueKey('study-timer-card'));
    expect(timer, findsOneWidget);
    expect(
      tester.getBottomLeft(timer).dy,
      closeTo(tester.getBottomLeft(find.byType(LibraryScreen)).dy, 1),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await planner.flush();
    planner.dispose();
    controller.dispose();
    await database.close();
  });
}
