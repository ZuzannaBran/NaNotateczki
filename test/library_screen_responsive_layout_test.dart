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
    for (final toggle in [navigationToggle, toolbarToggle]) {
      expect(tester.getSize(toggle), const Size(24, 44));
      final material = tester.widget<Material>(toggle);
      expect(material.elevation, 8);
      expect(material.shadowColor, Colors.black54);
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.width, 1);
      expect(shape.side.color.a, closeTo(0.6, 0.01));
    }
    expect(
      tester.getTopLeft(navigationToggle).dx,
      tester.getTopLeft(toolbarToggle).dx,
    );
    expect(tester.getCenter(navigationToggle).dy, closeTo(29, 0.01));
    expect(tester.getCenter(toolbarToggle).dy, closeTo(92, 0.01));
    expect(
      find.descendant(
        of: toolbarToggle,
        matching: find.byIcon(Icons.chevron_left),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Hide projects'));
    await tester.pump();
    expect(find.byTooltip('Show projects'), findsOneWidget);
    expect(find.byTooltip('Hide toolbar'), findsOneWidget);
    expect(tester.getTopLeft(navigationToggle).dx, 0);
    expect(tester.getTopLeft(toolbarToggle).dx, 0);
    expect(tester.getSize(navigationToggle).width, 24);
    expect(tester.getSize(toolbarToggle).width, 24);
    expect(tester.getCenter(navigationToggle).dy, closeTo(29, 0.01));
    expect(tester.getCenter(toolbarToggle).dy, closeTo(92, 0.01));
    expect(
      find.descendant(
        of: toolbarToggle,
        matching: find.byIcon(Icons.chevron_left),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Hide toolbar'));
    await tester.pump();
    expect(find.byType(EditorToolbar), findsNothing);
    expect(find.byTooltip('Show toolbar'), findsOneWidget);
    expect(tester.getCenter(toolbarToggle).dy, closeTo(92, 0.01));
    expect(
      find.descendant(
        of: toolbarToggle,
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );

    await controller.selectItem(notebook.uid);
    await tester.pump();
    expect(find.byType(EditorToolbar), findsNothing);

    await tester.tap(find.byTooltip('Show toolbar'));
    await tester.pump();
    expect(find.byType(EditorToolbar), findsOneWidget);
    expect(
      find.descendant(
        of: toolbarToggle,
        matching: find.byIcon(Icons.chevron_left),
      ),
      findsOneWidget,
    );

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
    final mainContainer = tester.widget<Container>(mainPanel);
    final textContainer = tester.widget<Container>(textPanel);
    expect(
      mainContainer.padding,
      const EdgeInsets.symmetric(horizontal: 22, vertical: 3),
    );
    expect(
      textContainer.padding,
      const EdgeInsets.symmetric(horizontal: 22, vertical: 2),
    );
    expect(tester.getSize(mainPanel).height, lessThan(66));
    expect(tester.getSize(textPanel).height, lessThan(60));

    for (final panel in [mainPanel, textPanel]) {
      final rect = tester.getRect(panel);
      expect(rect.width, lessThan(1600 - 104));
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
      expect(rect.width, closeTo(560 - 104, 0.01));
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

  testWidgets('vertical toolbars scroll and keep icon actions upright', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(850, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final controller = EditorController(
      repository: repository,
      notebook: notebook,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 120,
                height: 340,
                child: EditorToolbar(
                  axis: Axis.vertical,
                  controller: controller,
                  onInsertPressed: () {},
                  onExportSelected: (_) {},
                ),
              ),
              SizedBox(
                width: 152,
                height: 340,
                child: TextEditToolbar(
                  axis: Axis.vertical,
                  editorController: controller,
                  block: TextBlock(
                    id: 'vertical-text',
                    text: 'Text',
                    position: Offset.zero,
                    fontSize: 18,
                    color: Colors.black,
                    width: 150,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final inkPanel = find.byKey(const ValueKey('editor-toolbar-panel'));
    final textPanel = find.byKey(const ValueKey('text-toolbar-panel'));
    for (final panel in [inkPanel, textPanel]) {
      final scroll = find.descendant(
        of: panel,
        matching: find.byType(Scrollable),
      );
      expect(scroll, findsOneWidget);
      expect(
        tester.widget<Scrollable>(scroll).axisDirection,
        AxisDirection.down,
      );
      expect(
        tester.state<ScrollableState>(scroll).position.maxScrollExtent,
        greaterThan(0),
      );
    }
    expect(
      find.descendant(of: inkPanel, matching: find.byType(RotatedBox)),
      findsOneWidget,
    );
    expect(tester.getSize(inkPanel).width, lessThan(120));
    await tester.tap(find.byTooltip('Highlighter'));
    await tester.pump();
    expect(controller.tool, DrawingTool.highlighter);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });
}
