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
import 'package:program/features/editor/state/ink_color_presets.dart';
import 'package:program/features/library/presentation/library_catalog.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();

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

  test('canvas and folder palettes use the same global colors', () {
    expect(InkColorPreset.blue.colors, same(AppColors.blueColorSet));
    expect(InkColorPreset.pink.colors, same(AppColors.pinkColorSet));
    expect(InkColorPreset.green.colors, same(AppColors.greenColorSet));
  });

  test('recent folder cover colors persist in selection order', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    await repository.createNotebook(folder: 'Saved');
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await controller.loadItems();

    const pink = Color(0xFFE9D8DE);
    const blue = Color(0xFFD0D8E7);
    await controller.updateFolderCover(
      'Saved',
      const FolderCoverStyle(iconColor: pink),
    );
    await controller.updateFolderCover(
      'Saved',
      const FolderCoverStyle(iconColor: blue),
    );
    await controller.updateFolderCover(
      'Saved',
      const FolderCoverStyle(iconColor: pink),
    );
    expect(controller.recentCoverColors, [pink, blue]);
    expect((await SharedRecentColors.load()).take(2), [pink, blue]);

    final restored = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await restored.initialize();
    expect(restored.recentCoverColors, [pink, blue]);
    expect(restored.folderCoverFor('Saved').iconColor, pink);
    restored.dispose();
    controller.dispose();
    await database.close();
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
    final cover = find.byKey(
      const ValueKey('catalog-folder-cover:Physics'),
    );
    expect(cover, findsOneWidget);
    final initialFolderIcon = find.descendant(
      of: cover,
      matching: find.byType(FolderCoverIcon),
    );
    expect(initialFolderIcon, findsOneWidget);
    expect(
      tester.widget<FolderCoverIcon>(initialFolderIcon).shape,
      FolderCoverShape.folder,
    );
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
    final folderLabel = find.descendant(
      of: folderTile,
      matching: find.text('Physics'),
    );
    final folderCover = find.byKey(
      const ValueKey('catalog-folder-cover:Physics'),
    );
    final folderMenuRect = tester.getRect(folderMenu);
    final folderLabelRect = tester.getRect(folderLabel);
    final folderCoverRect = tester.getRect(folderCover);
    expect(folderMenuRect.left, closeTo(folderCoverRect.left, 1));
    expect(folderLabelRect.left, greaterThan(folderMenuRect.right));
    expect(folderLabelRect.right, lessThanOrEqualTo(folderCoverRect.right));
    expect(folderCoverRect.top - folderMenuRect.bottom, lessThan(12));
    expect(tester.widget<Text>(folderLabel).textAlign, TextAlign.left);
    expect(tester.widget<Text>(folderLabel).overflow, TextOverflow.ellipsis);
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
    for (final item in [note, board]) {
      final documentTile = find.byKey(
        ValueKey('catalog-document:${item.uid}'),
      );
      final documentMenu = find.descendant(
        of: documentTile,
        matching: find.byTooltip('Actions for ${item.title}'),
      );
      final documentLabel = find.descendant(
        of: documentTile,
        matching: find.text(item.title),
      );
      final previewArea = find.descendant(
        of: documentTile,
        matching: find.byType(InkWell),
      );
      final menuRect = tester.getRect(documentMenu);
      final labelRect = tester.getRect(documentLabel);
      final areaRect = tester.getRect(previewArea);
      expect(menuRect.left, closeTo(areaRect.left + 4, 1));
      expect(labelRect.left, greaterThan(menuRect.right));
      expect(labelRect.right, lessThanOrEqualTo(areaRect.right - 4));
      expect(areaRect.top - menuRect.bottom, lessThan(12));
      expect(tester.widget<Text>(documentLabel).textAlign, TextAlign.left);
      expect(tester.widget<Text>(documentLabel).overflow, TextOverflow.ellipsis);
    }

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
    expect(find.text('Cover decoration'), findsOneWidget);
    expect(find.text('Cover color'), findsNothing);
    final heartChoice = find.byKey(const ValueKey('cover-shape:heart'));
    expect(heartChoice, findsOneWidget);
    await tester.tap(heartChoice);
    await tester.pumpAndSettle();
    expect(find.text('Palettes'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    for (final preset in InkColorPreset.values) {
      for (final color in preset.colors) {
        expect(
          find.byKey(
            ValueKey('cover-palette-${preset.name}-${color.toARGB32()}'),
          ),
          findsOneWidget,
        );
      }
    }
    final firstPaletteColor = InkColorPreset.blue.colors[2];
    final paletteSwatch = find.byKey(
      ValueKey('cover-palette-blue-${firstPaletteColor.toARGB32()}'),
    );
    await tester.ensureVisible(paletteSwatch);
    await tester.tap(paletteSwatch);
    await tester.pumpAndSettle();
    final selectedPaletteSwatch = tester.widget<InkWell>(paletteSwatch);
    final paletteCircle = selectedPaletteSwatch.child! as Container;
    expect(paletteCircle.child, isA<Icon>());
    expect(
      (paletteCircle.decoration! as BoxDecoration).shape,
      BoxShape.circle,
    );
    expect(find.byKey(
      ValueKey('cover-color:${const Color(0xFF2E7D32).toARGB32()}'),
    ), findsNothing);
    for (final label in ['Blue', 'Pink', 'Green']) {
      final widget = tester.widget<Text>(find.text(label).last);
      expect(widget.style?.color,
          Theme.of(tester.element(find.text(label).last))
              .colorScheme.onSurface);
    }
    final advancedButton = find.byKey(const ValueKey('cover-advanced-color'));
    await tester.ensureVisible(advancedButton);
    await tester.tap(advancedButton);
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
    expect(
      controller.recentCoverColors.first,
      const Color(0xFF2B3C4D),
    );

    await tester.tap(folderMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit cover').last);
    await tester.pumpAndSettle();
    final recentSwatch = find.byKey(
      ValueKey(
        'cover-recent-${const Color(0xFF2B3C4D).toARGB32()}',
      ),
    );
    expect(recentSwatch, findsOneWidget);
    await tester.ensureVisible(recentSwatch);
    await tester.tap(recentSwatch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('catalog-document:${note.uid}')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorToolbar), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('projects-home')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-folders')), findsOneWidget);
    final savedCover = find.byKey(
      const ValueKey('catalog-folder-cover:Physics'),
    );
    expect(savedCover, findsOneWidget);
    final displayedFolderIcon = find.descendant(
      of: savedCover,
      matching: find.byType(FolderCoverIcon),
    );
    expect(displayedFolderIcon, findsOneWidget);
    final restoredIcon = tester.widget<FolderCoverIcon>(displayedFolderIcon);
    expect(restoredIcon.shape, FolderCoverShape.heart);
    expect(restoredIcon.color, const Color(0xFF2B3C4D));
    expect(
      find.descendant(
        of: displayedFolderIcon,
        matching: find.byKey(const ValueKey('folder-cover-decoration')),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await database.close();
  });

  testWidgets('Projects restores folder icons for saved cover shapes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    await repository.createNotebook(folder: 'Custom');
    await repository.createNotebook(folder: 'Plain');
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await controller.loadItems();
    const customColor = Color(0xFFCCA4B2);
    await controller.updateFolderCover(
      'Custom',
      const FolderCoverStyle(
        shape: FolderCoverShape.heart,
        iconColor: customColor,
      ),
    );

    for (final darkMode in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: darkMode ? AppTheme.dark() : AppTheme.light(),
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

      final customCover = find.byKey(
        const ValueKey('catalog-folder-cover:Custom'),
      );
      final plainCover = find.byKey(
        const ValueKey('catalog-folder-cover:Plain'),
      );
      expect(customCover, findsOneWidget);
      expect(plainCover, findsOneWidget);
      final customIcon = find.descendant(
        of: customCover,
        matching: find.byType(FolderCoverIcon),
      );
      final plainIcon = find.descendant(
        of: plainCover,
        matching: find.byType(FolderCoverIcon),
      );
      expect(customIcon, findsOneWidget);
      expect(plainIcon, findsOneWidget);
      expect(tester.widget<FolderCoverIcon>(customIcon).shape,
          FolderCoverShape.heart);
      expect(tester.widget<FolderCoverIcon>(plainIcon).shape,
          FolderCoverShape.folder);
      expect(
        tester.widget<FolderCoverIcon>(customIcon).color,
        AppColors.displayInkColor(customColor, darkMode: darkMode),
      );
      expect(
        tester.widget<FolderCoverIcon>(plainIcon).color,
        Theme.of(tester.element(plainIcon)).colorScheme.onSurface,
      );
      expect(
        find.descendant(
          of: customIcon,
          matching: find.byKey(const ValueKey('folder-cover-outline')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: customIcon,
          matching: find.byKey(const ValueKey('folder-cover-decoration')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: plainIcon,
          matching: find.byKey(const ValueKey('folder-cover-decoration')),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('Folder icons use the delicate Lucide stroke', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: FolderCoverIcon(
            shape: FolderCoverShape.flower,
            color: Colors.black,
          ),
        ),
      ),
    );
    final icon = find.byType(FolderCoverIcon);
    final outline = find.descendant(
      of: icon,
      matching: find.byKey(const ValueKey('folder-cover-outline')),
    );
    final decoration = find.descendant(
      of: icon,
      matching: find.byKey(const ValueKey('folder-cover-decoration')),
    );
    expect(outline, findsOneWidget);
    expect(decoration, findsOneWidget);
    final painter = tester.widget<CustomPaint>(outline).painter;
    expect(painter, isA<FolderCoverStrokePainter>());
    expect((painter! as FolderCoverStrokePainter).strokeWidth, 1.25);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Projects tiles keep rounded beige surfaces on hover', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final colored = await repository.createNotebook(
      folder: 'Soft folder',
    );
    final page = colored.pages.first.copyWith(
      inkStrokes: [
        InkStroke(
          id: 'black-ink',
          points: const [InkPoint(dx: 1, dy: 2, pressure: 1)],
          color: Colors.black,
          width: 2,
          tool: DrawingTool.pen,
        ),
      ],
    );
    expect(
      await repository.saveNotebook(colored.copyWith(pages: [page])),
      isTrue,
    );
    await repository.createNotebook(folder: 'Plain folder');
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
      final idleColor = isDark ? AppColors.darkPaper : AppColors.paper;
      expect(decoration.color, idleColor);
      final plainTile = find.byKey(
        const ValueKey('catalog-folder:Plain folder'),
      );
      final plainInk = tester.widget<Ink>(
        find.descendant(of: plainTile, matching: find.byType(Ink)),
      );
      expect((plainInk.decoration! as BoxDecoration).color, idleColor);
      final material = tester.widget<Material>(
        find.descendant(of: tile, matching: find.byType(Material)),
      );
      expect(material.clipBehavior, Clip.antiAlias);
      expect(material.borderRadius, BorderRadius.circular(24));

      final inkWell = tester.widget<InkWell>(
        find.descendant(of: tile, matching: find.byType(InkWell)),
      );
      expect(inkWell.borderRadius, BorderRadius.circular(24));
      expect(inkWell.overlayColor!.resolve({}), Colors.transparent);
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
