import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/editor/presentation/widgets/editor_toolbar.dart';
import 'package:program/features/library/presentation/library_catalog.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  test('folder cover settings round-trip and handle unknown shapes', () {
    const style = FolderCoverStyle(
      shape: FolderCoverShape.sparkle,
      iconColor: Color(0xFFB33636),
    );
    final restored = FolderCoverStyle.fromJson(style.toJson());
    expect(restored.shape, FolderCoverShape.sparkle);
    expect(restored.iconColor, const Color(0xFFB33636));
    expect(
      FolderCoverStyle.fromJson({'shape': 'old-value'}).shape,
      FolderCoverShape.folder,
    );
    expect(
      FolderCoverStyle.fromJson(null).iconColor,
      isNull,
    );
  });

  test('folder cover reflects the dominant content color', () {
    final now = DateTime(2026, 1, 1);
    final page = NotePage(
      id: 'p1',
      title: 'First page',
      textBlocks: [],
      imageBlocks: [],
      inkStrokes: [
        for (var index = 0; index < 3; index++)
          InkStroke(
            id: 'blue-$index',
            points: const [InkPoint(dx: 1, dy: 2, pressure: 1)],
            color: Colors.blue,
            width: 2,
            tool: DrawingTool.pen,
          ),
        InkStroke(
          id: 'red',
          points: const [InkPoint(dx: 1, dy: 2, pressure: 1)],
          color: Colors.red,
          width: 2,
          tool: DrawingTool.pen,
        ),
      ],
      isBookmarked: false,
    );
    final document = Notebook(
      uid: 'n1',
      title: 'Colors',
      kind: NotebookKind.notebook,
      folder: 'Physics',
      createdAt: now,
      updatedAt: now,
      pages: [page],
    );
    expect(dominantFolderColor([document]), Colors.blue);
  });

  testWidgets('starts in folder grid, previews both kinds, and returns home', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final note = await repository.createNotebook(folder: 'Physics');
    final board = await repository.createBoard(folder: 'Physics');
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    final preferences = AppPreferencesController();
    await controller.loadItems();

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
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('catalog-folders')), findsOneWidget);
    expect(find.byType(EditorToolbar), findsNothing);

    await tester.tap(find.byKey(const ValueKey('catalog-folder:Physics')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey('catalog-document:${note.uid}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('catalog-document:${board.uid}')),
      findsOneWidget,
    );

    final noteRatio = find.descendant(
      of: find.byKey(ValueKey('catalog-document:${note.uid}')),
      matching: find.byType(AspectRatio),
    );
    final boardRatio = find.descendant(
      of: find.byKey(ValueKey('catalog-document:${board.uid}')),
      matching: find.byType(AspectRatio),
    );
    expect(tester.widget<AspectRatio>(noteRatio).aspectRatio, 0.72);
    expect(tester.widget<AspectRatio>(boardRatio).aspectRatio, 1);

    await tester.tap(find.byTooltip('Edit folder cover'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cover-shape:heart')));
    await tester.tap(
      find.byKey(
        ValueKey('cover-color:${const Color(0xFF2E7D32).toARGB32()}'),
      ),
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(controller.folderCoverFor('Physics').shape, FolderCoverShape.heart);
    expect(
      controller.folderCoverFor('Physics').iconColor,
      const Color(0xFF2E7D32),
    );

    await tester.tap(find.byKey(ValueKey('catalog-document:${note.uid}')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorToolbar), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('projects-home')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-folders')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await database.close();
  });
}
