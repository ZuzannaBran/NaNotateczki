import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';
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
    expect(FolderCoverStyle.fromJson(null).iconColor, isNull);
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
    expect(dominantFolderColor([document]).toARGB32(), Colors.blue.toARGB32());
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
    expect(find.byType(FolderCoverIcon), findsWidgets);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

    final catalogHeader = find.ancestor(
      of: find.byKey(const ValueKey('catalog-title')),
      matching: find.byType(AppBar),
    );
    expect(catalogHeader, findsOneWidget);
    expect(tester.widget<AppBar>(catalogHeader).titleSpacing, 44);
    expect(tester.getSize(catalogHeader).height, 56);

    final folderTile = find.byKey(const ValueKey('catalog-folder:Physics'));
    final folderMenu = find.descendant(
      of: folderTile,
      matching: find.byTooltip('Actions for Physics'),
    );
    expect(
      tester.getTopLeft(folderMenu).dy,
      lessThan(tester.getTopLeft(folderTile).dy + 70),
    );
    await tester.tap(folderTile);
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey('catalog-document:${note.uid}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('catalog-document:${board.uid}')),
      findsOneWidget,
    );
    final noteTile = find.byKey(ValueKey('catalog-document:${note.uid}'));
    final itemMenu = find.descendant(
      of: noteTile,
      matching: find.byTooltip('Actions for ${note.title}'),
    );
    expect(
      tester.getTopLeft(itemMenu).dy,
      lessThan(tester.getTopLeft(noteTile).dy + 70),
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
    final heartOption = find.byKey(const ValueKey('cover-shape:heart'));
    final heartPreview = find.descendant(
      of: heartOption,
      matching: find.byType(FolderCoverIcon),
    );
    expect(tester.widget<FolderCoverIcon>(heartPreview).shape,
        FolderCoverShape.heart);
    expect(
      find.descendant(
        of: heartPreview,
        matching: find.byKey(const ValueKey('folder-cover-outline')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: heartPreview,
        matching: find.byKey(const ValueKey('folder-cover-decoration')),
      ),
      findsOneWidget,
    );
    await tester.tap(heartOption);
    await tester.tap(
      find.byKey(ValueKey('cover-color:${const Color(0xFF2E7D32).toARGB32()}')),
    );
    await tester.tap(find.byKey(const ValueKey('cover-advanced-color')));
    await tester.pumpAndSettle();
    expect(find.text('Pick color'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(4));
    await tester.enterText(find.byType(TextField).last, '#2B3C4D');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Pick color'), findsNothing);
    expect(find.text('Edit folder cover'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(controller.folderCoverFor('Physics').shape, FolderCoverShape.heart);
    expect(
      controller.folderCoverFor('Physics').iconColor,
      const Color(0xFF2B3C4D),
    );

    await tester.tap(find.byKey(ValueKey('catalog-document:${note.uid}')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorToolbar), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('projects-home')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-folders')), findsOneWidget);
    final selectedCover = find.descendant(
      of: folderTile,
      matching: find.byType(FolderCoverIcon),
    );
    expect(tester.widget<FolderCoverIcon>(selectedCover).shape,
        FolderCoverShape.heart);
    expect(
      find.descendant(
        of: selectedCover,
        matching: find.byKey(const ValueKey('folder-cover-outline')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: selectedCover,
        matching: find.byKey(const ValueKey('folder-cover-decoration')),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await database.close();
  });

  testWidgets('Lucide folder covers keep a thin stroke at every size', (
    tester,
  ) async {
    for (final size in [32.0, 88.0, 120.0]) {
      for (final shape in FolderCoverShape.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: FolderCoverIcon(
                shape: shape,
                color: Colors.black,
                size: size,
                semanticLabel: 'Folder cover',
              ),
            ),
          ),
        );

        final cover = find.byType(FolderCoverIcon);
        final outline = find.descendant(
          of: cover,
          matching: find.byKey(const ValueKey('folder-cover-outline')),
        );
        expect(outline, findsOneWidget);
        final outlinePainter = tester.widget<CustomPaint>(outline).painter;
        expect(outlinePainter, isA<FolderCoverStrokePainter>());
        final folderPainter = outlinePainter! as FolderCoverStrokePainter;
        expect(folderPainter.strokeWidth, 1.25);
        expect(folderPainter.smoothingSigma, 0.55);
        expect(folderPainter.color, Colors.black);
        expect(folderPainter.isDecoration, false);

        final decoration = find.descendant(
          of: cover,
          matching: find.byKey(const ValueKey('folder-cover-decoration')),
        );
        if (shape == FolderCoverShape.folder) {
          expect(decoration, findsNothing);
        } else {
          expect(decoration, findsOneWidget);
          final symbolPainter = tester.widget<CustomPaint>(decoration).painter;
          expect(symbolPainter, isA<FolderCoverStrokePainter>());
          expect(
            (symbolPainter! as FolderCoverStrokePainter).isDecoration,
            isTrue,
          );
          expect(symbolPainter.shape, shape);
          expect(symbolPainter.strokeWidth, 1.25);
          expect(symbolPainter.smoothingSigma, 0.55);
        }
        expect(
          find.descendant(of: cover, matching: find.byType(Icon)),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('cover smoothing follows device pixel density', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: FolderCoverIcon(
            shape: FolderCoverShape.heart,
            color: Colors.black,
          ),
        ),
      ),
    );

    final cover = find.byType(FolderCoverIcon);
    final strokes = find.descendant(
      of: cover,
      matching: find.byType(CustomPaint),
    );
    final painters = tester.widgetList<CustomPaint>(strokes).map(
      (widget) => widget.painter,
    );
    for (final painter in painters) {
      expect(painter, isA<FolderCoverStrokePainter>());
      final stroke = painter! as FolderCoverStrokePainter;
      expect(stroke.devicePixelRatio, 2.0);
      expect(stroke.smoothingSigma, closeTo(0.275, 0.001));
    }
  });

  testWidgets('Projects tiles keep rounded beige surfaces on hover', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    await repository.createNotebook(folder: 'Soft folder');
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await controller.loadItems();

    for (final isDark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: isDark ? AppTheme.dark() : AppTheme.light(),
          home: LibraryCatalog(
            controller: controller,
            folder: null,
            onBack: () {},
            onFolderTap: (_) {},
            onOpenItem: (_) {},
            onEditFolder: (_) {},
            onRenameFolder: (_) {},
            onDeleteFolder: (_) {},
            onRenameItem: (_) {},
            onDeleteItem: (_) {},
            onSettings: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tile = find.byKey(const ValueKey('catalog-folder:Soft folder'));
      final ink = tester.widget<Ink>(
        find.descendant(of: tile, matching: find.byType(Ink)),
      );
      final decoration = ink.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(24));
      expect(
        decoration.color,
        Color.lerp(
          isDark ? AppColors.darkPaper : AppColors.paper,
          isDark
              ? AppColors.displayInkColor(
                  AppColors.divider,
                  darkMode: true,
                )
              : AppColors.divider,
          0.10,
        ),
      );
      final material = tester.widget<Material>(
        find.descendant(of: tile, matching: find.byType(Material)),
      );
      expect(material.clipBehavior, Clip.antiAlias);
      expect(material.borderRadius, BorderRadius.circular(24));

      final inkWell = tester.widget<InkWell>(
        find.descendant(of: tile, matching: find.byType(InkWell)),
      );
      expect(inkWell.borderRadius, BorderRadius.circular(24));
      expect(
        inkWell.overlayColor!.resolve({WidgetState.hovered}),
        (isDark ? AppColors.darkActive : AppColors.toolbar)
            .withValues(alpha: isDark ? 0.32 : 0.52),
      );
      expect(
        inkWell.overlayColor!.resolve({WidgetState.pressed}),
        (isDark ? AppColors.darkActive : AppColors.divider)
            .withValues(alpha: isDark ? 0.52 : 0.42),
      );
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('Projects uses top-aligned responsive five-column folder grid', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    for (var index = 1; index <= 7; index++) {
      await repository.createNotebook(folder: 'Folder $index');
    }
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await controller.loadItems();

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryCatalog(
          controller: controller,
          folder: null,
          onBack: () {},
          onFolderTap: (_) {},
          onOpenItem: (_) {},
          onEditFolder: (_) {},
          onRenameFolder: (_) {},
          onDeleteFolder: (_) {},
          onRenameItem: (_) {},
          onDeleteItem: (_) {},
          onSettings: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final grid = find.byKey(const ValueKey('catalog-folder-grid'));
    final tiles = [
      for (var index = 1; index <= 7; index++)
        find.byKey(ValueKey('catalog-folder:Folder $index')),
    ];
    expect(tester.getSize(grid).width, 1230);
    expect(tester.getCenter(grid).dx, closeTo(800, 1));
    expect(tester.getTopLeft(grid).dy, closeTo(80, 1));
    for (var index = 1; index < 5; index++) {
      expect(
        tester.getTopLeft(tiles[index]).dy,
        closeTo(tester.getTopLeft(tiles[0]).dy, 1),
      );
    }
    expect(
      tester.getTopLeft(tiles[5]).dy,
      greaterThan(tester.getTopLeft(tiles[0]).dy),
    );
    expect(
      tester.getTopLeft(tiles[5]).dx,
      closeTo(tester.getTopLeft(tiles[0]).dx, 1),
    );
    expect(
      tester.getTopLeft(tiles[6]).dx,
      closeTo(tester.getTopLeft(tiles[1]).dx, 1),
    );
    expect(
      find.byKey(const ValueKey('catalog-vertical-divider:0:0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('catalog-horizontal-divider:0')),
      findsNothing,
    );

    await tester.binding.setSurfaceSize(const Size(580, 900));
    await tester.pumpAndSettle();
    expect(tester.getSize(grid).width, 492);
    expect(
      tester.getTopLeft(tiles[2]).dy,
      greaterThan(tester.getTopLeft(tiles[0]).dy),
    );
    expect(
      tester.getTopLeft(tiles[1]).dy,
      closeTo(tester.getTopLeft(tiles[0]).dy, 1),
    );
    expect(
      tester.getTopLeft(tiles[6]).dx,
      closeTo(tester.getTopLeft(tiles[0]).dx, 1),
    );

    await tester.binding.setSurfaceSize(const Size(390, 900));
    await tester.pumpAndSettle();
    expect(tester.getSize(grid).width, 246);
    expect(tester.getCenter(grid).dx, closeTo(195, 1));
    expect(tester.getTopLeft(grid).dy, closeTo(80, 1));
    expect(
      tester.getTopLeft(tiles[1]).dy,
      greaterThan(tester.getTopLeft(tiles[0]).dy),
    );
    expect(
      find.byKey(const ValueKey('catalog-vertical-divider:0:0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('catalog-horizontal-divider:3')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });
}
