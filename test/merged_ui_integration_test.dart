import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/input/touch_navigation_scroll_physics.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/editor/presentation/editor_settings_screen.dart';
import 'package:program/features/library/presentation/library_catalog.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/text_block.dart';
import 'package:program/features/planner/presentation/planner_screen.dart';
import 'package:program/features/planner/presentation/study_timer_widgets.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();
  setUpAll(() async {
    const fontPath = String.fromEnvironment('MERGE_REVIEW_FONT');
    if (fontPath.isNotEmpty) {
      final loader = FontLoader('Georgia')
        ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
    const iconFontPath = String.fromEnvironment('MERGE_REVIEW_ICON_FONT');
    if (iconFontPath.isNotEmpty) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(File(iconFontPath).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  testWidgets('empty catalog and planner share live appearance settings', (
    tester,
  ) async {
    final app = await _pumpApp(tester, withDocuments: false);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsScreen), findsOneWidget);
    await tester.tap(find.text('Visual'));
    await tester.pumpAndSettle();
    await _tapAppearance(tester, 'Dark');
    await tester.pumpAndSettle();
    expect(app.preferences.darkMode, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    _expectCatalogBackground(tester, AppColors.darkBackground);

    await tester.tap(find.byTooltip('Open planner'));
    await tester.pumpAndSettle();
    expect(find.byType(PlannerScreen), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(PlannerScreen))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsScreen), findsOneWidget);
    await tester.tap(find.text('Visual'));
    await tester.pumpAndSettle();
    await _tapAppearance(tester, 'Light');
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(PlannerScreen))).brightness,
      Brightness.light,
    );
    await tester.tap(find.byTooltip('Back to notes'));
    await tester.pumpAndSettle();
    _expectCatalogBackground(tester, AppColors.background);
    expect(tester.takeException(), isNull);
    await app.close(tester);
  });

  testWidgets('dark catalog previews invert ink without changing documents', (
    tester,
  ) async {
    final app = await _pumpApp(tester, darkMode: true);
    _expectCatalogBackground(tester, AppColors.darkBackground);
    await _snapshot(tester, 'catalog-dark');
    final folder = find.byKey(const ValueKey('catalog-folder:Project'));
    final icon = tester.widget<Icon>(
      find.descendant(of: folder, matching: find.byIcon(Icons.folder_outlined)),
    );
    expect(icon.color, AppColors.darkText);
    await tester.tap(folder);
    await tester.pumpAndSettle();
    await _snapshot(tester, 'documents-dark');
    final darkPainters = <String, CustomPainter>{};

    for (final notebook in app.documents) {
      final tile = find.byKey(ValueKey('catalog-document:${notebook.uid}'));
      final paint = find.descendant(
        of: tile,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter.runtimeType.toString() == '_PagePreviewPainter',
        ),
      );
      expect(paint, findsOneWidget);
      expect(
        find.descendant(
          of: tile,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is ColoredBox && widget.color == AppColors.darkCanvas,
          ),
        ),
        findsOneWidget,
      );
      final painter = tester.widget<CustomPaint>(paint).painter!;
      darkPainters[notebook.uid] = painter;
      expect(
        (Canvas canvas) => painter.paint(canvas, const Size(820, 1160)),
        paints..path(color: Colors.white),
      );
      final saved = app.library.items.singleWhere(
        (item) => item.uid == notebook.uid,
      );
      expect(saved.pages.single.inkStrokes.single.color, Colors.black);
      expect(saved.pages.single.textBlocks.single.color, Colors.black);
    }
    await tester.runAsync(() => app.preferences.setDarkMode(false));
    await tester.pumpAndSettle();
    _expectCatalogBackground(tester, AppColors.background);
    for (final notebook in app.documents) {
      final tile = find.byKey(ValueKey('catalog-document:${notebook.uid}'));
      final paint = find.descendant(
        of: tile,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter.runtimeType.toString() == '_PagePreviewPainter',
        ),
      );
      final painter = tester.widget<CustomPaint>(paint).painter!;
      expect(painter.shouldRepaint(darkPainters[notebook.uid]!), isTrue);
      expect(
        (Canvas canvas) => painter.paint(canvas, const Size(820, 1160)),
        paints..path(color: Colors.black),
      );
    }
    await _snapshot(tester, 'documents-light');
    expect(tester.takeException(), isNull);
    await app.close(tester);
  });

  testWidgets('planner actions dialogs and compact timer respect dark mode', (
    tester,
  ) async {
    final app = await _pumpApp(tester, darkMode: true);
    await tester.tap(find.byKey(const ValueKey('library-navigation-toggle')));
    await tester.pumpAndSettle();
    final compact = find.byKey(const ValueKey('compact-study-timer'));
    expect(compact, findsOneWidget);
    final material = tester.widget<Material>(
      find.ancestor(of: compact, matching: find.byType(Material)).first,
    );
    expect(material.color, AppColors.darkToolbar);
    await tester.tap(compact);
    await tester.pumpAndSettle();
    final create = find.widgetWithText(FilledButton, 'New session');
    final theme = Theme.of(tester.element(create));
    final button = tester.widget<FilledButton>(create);
    expect(button.style!.foregroundColor!.resolve({}), AppColors.darkText);
    expect(button.style!.backgroundColor!.resolve({}), AppColors.darkActive);
    expect(theme.brightness, Brightness.dark);
    final toggle = tester.widget<SegmentedButton<CalendarMode>>(
      find.byType(SegmentedButton<CalendarMode>),
    );
    final scoped = Theme.of(
      tester.element(find.byType(SegmentedButton<CalendarMode>)),
    );
    final toggleStyle = toggle.style ?? scoped.segmentedButtonTheme.style!;
    expect(toggleStyle.foregroundColor!.resolve({}), AppColors.darkText);
    await _snapshot(tester, 'planner-dark');
    await tester.tap(create);
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(Theme.of(tester.element(save)).brightness, Brightness.dark);
    expect(
      tester.widget<FilledButton>(save).style!.foregroundColor!.resolve({}),
      AppColors.darkText,
    );
    await _snapshot(tester, 'session-dialog-dark');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await app.close(tester);
  });

  for (final darkMode in [false, true]) {
    testWidgets('sidebar menus preserve dev_ui geometry in dark=$darkMode', (
      tester,
    ) async {
      final app = await _pumpApp(tester, darkMode: darkMode);
      for (final resized in [false, true]) {
        if (resized) {
          final edge = tester
              .getTopLeft(
                find.byKey(const ValueKey('library-navigation-toggle')),
              )
              .dx;
          await tester.dragFrom(Offset(edge - 5, 200), const Offset(70, 0));
          await tester.pumpAndSettle();
        }
        final panelEdge =
            tester
                .getTopLeft(
                  find.byKey(const ValueKey('library-navigation-toggle')),
                )
                .dx +
            1 -
            12;
        for (final (name, button, width, count) in [
          ('folder', find.byTooltip('Folder actions'), 130.0, 3),
          ('document', find.byTooltip('Item actions').first, 130.0, 2),
          ('create', find.byTooltip('Create'), 150.0, 3),
        ]) {
          final top = tester.getTopLeft(button).dy;
          await tester.tap(button);
          await tester.pumpAndSettle();
          final entries = find.byWidgetPredicate(
            (widget) => widget is PopupMenuItem && widget.height == 36,
          );
          expect(entries, findsNWidgets(count));
          final rect = tester.getRect(entries.first);
          expect(rect.left, closeTo(panelEdge, 1));
          expect(rect.top, closeTo(top, 4));
          expect(rect.width, closeTo(width, 1));
          final theme = Theme.of(tester.element(entries.first));
          expect(
            theme.brightness,
            darkMode ? Brightness.dark : Brightness.light,
          );
          final material = tester
              .widgetList<Material>(
                find.ancestor(
                  of: entries.first,
                  matching: find.byType(Material),
                ),
              )
              .firstWhere((widget) => widget.shape is RoundedRectangleBorder);
          expect(material.color, theme.colorScheme.surfaceContainerLowest);
          expect(material.elevation, 4);
          expect(material.shadowColor, const Color(0x44000000));
          expect(
            (material.shape! as RoundedRectangleBorder).borderRadius,
            const BorderRadius.only(
              topRight: Radius.circular(12),
              bottomRight: Radius.circular(12),
            ),
          );
          final label = find.descendant(
            of: entries.first,
            matching: find.byType(Text),
          );
          expect(tester.widget<Text>(label).style!.fontSize, 14);
          expect(
            tester.widget<Text>(label).style!.color,
            theme.colorScheme.onSurface,
          );
          expect(
            DefaultTextStyle.of(tester.element(label)).style.fontFamily,
            'Georgia',
          );
          await _snapshot(
            tester,
            'menu-$name-${darkMode ? 'dark' : 'light'}-'
            '${resized ? 'resized' : 'default'}',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
      }
      expect(tester.takeException(), isNull);
      await app.close(tester);
    });
  }

  testWidgets('catalog and calendar follow live touch sensitivity', (
    tester,
  ) async {
    final app = await _pumpApp(tester);
    app.preferences.previewTouchNavigationSensitivity(1.8);
    await tester.pumpAndSettle();
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('catalog-folders')),
    );
    expect(grid.physics, isA<TouchNavigationScrollPhysics>());
    expect((grid.physics! as TouchNavigationScrollPhysics).sensitivity, 1.8);
    await tester.tap(find.byTooltip('Open planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Today').last);
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    expect(
      tester.widget<ListView>(list).physics,
      isA<TouchNavigationScrollPhysics>(),
    );
    app.preferences.previewTouchNavigationSensitivity(0.6);
    await tester.pumpAndSettle();
    expect(
      (tester.widget<ListView>(list).physics! as TouchNavigationScrollPhysics)
          .sensitivity,
      0.6,
    );
    expect(tester.takeException(), isNull);
    await app.close(tester);
  });

  testWidgets('sidebar timer and session form use live touch sensitivity', (
    tester,
  ) async {
    final app = await _pumpApp(tester);
    app.preferences.previewTouchNavigationSensitivity(1.8);
    await tester.pumpAndSettle();
    final timerScroll = find.ancestor(
      of: find.byType(StudyTimerCard),
      matching: find.byType(SingleChildScrollView),
    );
    expect(timerScroll, findsOneWidget);
    expect(
      tester.widget<SingleChildScrollView>(timerScroll).physics,
      isA<TouchNavigationScrollPhysics>(),
    );
    await tester.tap(find.byTooltip('Open planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session'));
    await tester.pumpAndSettle();
    final formScroll = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(SingleChildScrollView),
    );
    expect(formScroll, findsOneWidget);
    expect(
      (tester.widget<SingleChildScrollView>(formScroll).physics!
              as TouchNavigationScrollPhysics)
          .sensitivity,
      1.8,
    );
    app.preferences.previewTouchNavigationSensitivity(0.6);
    await tester.pumpAndSettle();
    expect(
      (tester.widget<SingleChildScrollView>(formScroll).physics!
              as TouchNavigationScrollPhysics)
          .sensitivity,
      0.6,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to notes'));
    await tester.pumpAndSettle();
    expect(
      (tester.widget<SingleChildScrollView>(timerScroll).physics!
              as TouchNavigationScrollPhysics)
          .sensitivity,
      0.6,
    );
    await app.close(tester);
  });
}

void _expectCatalogBackground(WidgetTester tester, Color color) {
  final background = find.descendant(
    of: find.byType(LibraryCatalog),
    matching: find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.color == color,
    ),
  );
  expect(background, findsWidgets);
}

Future<void> _tapAppearance(WidgetTester tester, String label) async {
  // Native preference writes must finish outside the widget FakeAsync zone.
  await tester.runAsync(() async {
    await tester.tap(find.text(label));
    await readStoredText('app_prefs.json');
  });
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('MERGE_REVIEW_SNAPSHOTS')) {
    return;
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('merged-app-snapshot')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    const prefix = String.fromEnvironment(
      'MERGE_REVIEW_PREFIX',
      defaultValue: 'review',
    );
    await File(
      '/tmp/nanotateczki-$prefix-$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<_MergedApp> _pumpApp(
  WidgetTester tester, {
  bool withDocuments = true,
  bool darkMode = false,
}) async {
  final previousDisableShadows = debugDisableShadows;
  if (const bool.fromEnvironment('MERGE_REVIEW_SNAPSHOTS')) {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = previousDisableShadows);
  }
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final database = NotesDatabase(NativeDatabase.memory());
  addTearDown(database.close);
  final repository = NotebookRepository(database);
  final documents = <Notebook>[];
  if (withDocuments) {
    for (final document in [
      await repository.createNotebook(title: 'Notebook', folder: 'Project'),
      await repository.createBoard(title: 'Board', folder: 'Project'),
    ]) {
      final seeded = document.copyWith(
        pages: [
          document.pages.single.copyWith(
            inkStrokes: [
              InkStroke(
                id: 'ink-${document.uid}',
                points: const [
                  InkPoint(dx: 80, dy: 100, pressure: 1),
                  InkPoint(dx: 200, dy: 100, pressure: 1),
                ],
                color: Colors.black,
                width: 10,
                tool: DrawingTool.pen,
              ),
            ],
            textBlocks: [
              TextBlock(
                id: 'text-${document.uid}',
                text: 'Saved text',
                position: const Offset(80, 250),
                fontSize: 22,
                color: Colors.black,
                width: 400,
              ),
            ],
          ),
        ],
      );
      await repository.saveNotebook(seeded);
      documents.add(seeded);
    }
  }
  final library = LibraryController(
    repository,
    CloudSyncService(repository),
    LocalBackupService(repository),
  );
  await library.loadItems();
  final preferences = AppPreferencesController()..darkMode = darkMode;
  final planner = StudyPlannerController(
    autoTick: false,
    read: (_) async => null,
    write: (_, _) async {},
  );
  await planner.load();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryController>.value(value: library),
        ChangeNotifierProvider<AppPreferencesController>.value(
          value: preferences,
        ),
        ChangeNotifierProvider<StudyPlannerController>.value(value: planner),
        Provider<NotebookRepository>.value(value: repository),
      ],
      child: RepaintBoundary(
        key: const ValueKey('merged-app-snapshot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          builder: (context, child) => Consumer<AppPreferencesController>(
            builder: (context, preferences, _) => Theme(
              data: preferences.darkMode ? AppTheme.dark() : AppTheme.light(),
              child: child!,
            ),
          ),
          home: const LibraryScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _MergedApp(
    database,
    repository,
    library,
    preferences,
    planner,
    documents,
    previousDisableShadows,
  );
}

class _MergedApp {
  _MergedApp(
    this.database,
    this.repository,
    this.library,
    this.preferences,
    this.planner,
    this.documents,
    this.previousDisableShadows,
  );

  final NotesDatabase database;
  final NotebookRepository repository;
  final LibraryController library;
  final AppPreferencesController preferences;
  final StudyPlannerController planner;
  final List<Notebook> documents;
  final bool previousDisableShadows;

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    debugDisableShadows = previousDisableShadows;
    await planner.flush();
    planner.dispose();
    library.dispose();
    preferences.dispose();
    await repository.waitForPendingSaves();
  }
}
