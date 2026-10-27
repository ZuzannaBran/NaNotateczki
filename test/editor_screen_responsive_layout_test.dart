import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/input/touch_navigation_scroll_physics.dart';
import 'package:program/core/theme/app_metrics.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/presentation/widgets/editor_toolbar.dart';
import 'package:program/features/editor/presentation/widgets/page_background_paint.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/page_background.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();

  testWidgets(
    'background switches repaint without notifying the whole editor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final database = NotesDatabase(NativeDatabase.memory());
      final preferences = AppPreferencesController();
      final controller = EditorController(
        repository: NotebookRepository(database),
        notebook: _notebook(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppPreferencesController>.value(
                value: preferences,
              ),
              ChangeNotifierProvider<EditorController>.value(value: controller),
            ],
            child: const EditorScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();

      var editorNotifications = 0;
      var backgroundNotifications = 0;
      controller.addListener(() => editorNotifications++);
      controller.backgroundSettingsListenable.addListener(
        () => backgroundNotifications++,
      );

      final painterFinder = find.byType(PageBackgroundPaint);
      expect(painterFinder, findsWidgets);

      controller.setCurrentBackgroundSettings(
        const PageBackgroundSettings(style: PageBackgroundStyle.grid),
      );
      expect(editorNotifications, 0);
      expect(backgroundNotifications, 1);
      await tester.pump();
      expect(
        tester.widget<PageBackgroundPaint>(painterFinder.first).settings.style,
        PageBackgroundStyle.grid,
      );

      controller.setCurrentBackgroundSettings(
        const PageBackgroundSettings(style: PageBackgroundStyle.lines),
      );
      controller.setCurrentBackgroundSettings(
        const PageBackgroundSettings(style: PageBackgroundStyle.lines),
      );
      expect(editorNotifications, 0);
      expect(backgroundNotifications, 2);
      await tester.pump();
      expect(
        tester.widget<PageBackgroundPaint>(painterFinder.first).settings.style,
        PageBackgroundStyle.lines,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      preferences.dispose();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await database.close();
    },
  );

  testWidgets('page stays clear of overview and inside right boundary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebook(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<EditorController>.value(value: controller),
          ],
          child: const EditorScreen(),
        ),
      ),
    );
    await tester.pump();

    const logicalPageWidth = 820.0;
    expect(
      controller.layoutPageSize,
      const Size(logicalPageWidth, logicalPageWidth * AppMetrics.a4HeightRatio),
    );
    expect(_documentLayoutSize(tester).width, logicalPageWidth);
    expect(_documentScale(tester), closeTo(1.0, 0.001));
    expect(_documentTranslationX(tester), closeTo(4.0, 0.001));
    final wideViewportRightMargin =
        1000 -
        tester
            .getTopRight(find.byKey(const ValueKey('notebook-page-viewport')))
            .dx;
    expect(wideViewportRightMargin, closeTo(56.0, 0.001));
    expect(
      1000 - _documentTopRight(tester).dx,
      greaterThanOrEqualTo(wideViewportRightMargin),
    );
    expect(_pageViewportSize(tester).width, closeTo(828.0, 0.001));
    _expectOverviewSideGapsEqual(tester);

    await tester.binding.setSurfaceSize(const Size(500, 900));
    await tester.pump();

    expect(
      controller.layoutPageSize,
      const Size(logicalPageWidth, logicalPageWidth * AppMetrics.a4HeightRatio),
    );
    expect(_documentLayoutSize(tester).width, logicalPageWidth);
    expect(_documentScale(tester), closeTo((500 - 24) / 820, 0.001));
    final narrowRightMargin = 500 - _documentTopRight(tester).dx;
    expect(narrowRightMargin, closeTo(12.0, 0.001));
    expect(_pageViewportSize(tester).width, closeTo(476.0, 0.001));
    expect(_documentTranslationX(tester), closeTo(0.0, 0.001));
    expect(
      find.byKey(const ValueKey('notebook-project-overview')),
      findsNothing,
    );
    expect(find.text('Widen the window to edit this notebook.'), findsNothing);

    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pump();

    expect(_documentScale(tester), closeTo(1.0, 0.001));
    expect(_pageViewportSize(tester).width, closeTo(928.0, 0.001));
    expect(_documentTranslationX(tester), closeTo(54.0, 0.001));

    final viewportCenter = tester.getCenter(
      find.byKey(const ValueKey('notebook-page-viewport')),
    );
    final firstFinger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 1,
    );
    final secondFinger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 2,
    );
    await firstFinger.down(viewportCenter + const Offset(-60, 0));
    await secondFinger.down(viewportCenter + const Offset(60, 0));
    await tester.pump();

    await firstFinger.moveBy(const Offset(80, 0));
    await tester.pump();
    await secondFinger.moveBy(const Offset(80, 0));
    await tester.pump();

    final translatedX = _documentTranslationX(tester);
    expect(translatedX, greaterThan(54.0));
    expect(translatedX, lessThanOrEqualTo(108.0));

    await firstFinger.up();
    await secondFinger.up();
    await tester.pump();

    controller.setTool(DrawingTool.highlighter);
    await tester.pump();
    expect(_documentTranslationX(tester), closeTo(translatedX, 0.001));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });

  testWidgets('zoomed notebook can scroll to either end from a middle page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebook(pageCount: 7),
    );
    controller.setTool(DrawingTool.edit);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<EditorController>.value(value: controller),
          ],
          child: const EditorScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining(RegExp(r'^\d+%$')), findsNothing);

    final scrollView = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('notebook-document-scroll')),
    );
    final scroll = scrollView.controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pump();
    expect(scroll.offset, greaterThan(1000));

    const viewportKey = ValueKey('notebook-page-viewport');
    final viewport = find.byKey(viewportKey);
    final pointer = Offset(
      tester.getTopLeft(viewport).dx + 240,
      tester.getTopLeft(find.byKey(const ValueKey('notebook-canvas-area'))).dy +
          230,
    );
    final firstFinger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 31,
    );
    final secondFinger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 32,
    );
    await firstFinger.down(pointer + const Offset(-40, 0));
    await secondFinger.down(pointer + const Offset(40, 0));
    await tester.pump();
    await firstFinger.moveBy(const Offset(-60, 0));
    await tester.pump();
    await secondFinger.moveBy(const Offset(60, 0));
    await tester.pump();
    await firstFinger.up();
    await secondFinger.up();
    await tester.pump();

    expect(_documentScale(tester), greaterThan(1.001));
    expect(find.textContaining(RegExp(r'^\d+%$')), findsNothing);
    final scaledDocumentHeight =
        _documentLayoutSize(tester).height * _documentScale(tester);
    expect(
      _pageViewportSize(tester).height,
      greaterThanOrEqualTo(scaledDocumentHeight - 0.01),
    );

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: pointer,
        scrollDelta: const Offset(0, -100000),
      ),
    );
    await tester.pump();
    expect(scroll.offset, closeTo(scroll.position.minScrollExtent, 1));
    expect(
      _documentTopLeft(tester).dy,
      greaterThanOrEqualTo(tester.getTopLeft(viewport).dy - 1),
    );

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: pointer,
        scrollDelta: const Offset(0, 100000),
      ),
    );
    await tester.pump();
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    // The final scroll position must expose the scaled footer and margin.
    await tester.pump();
    final addPageButton = find.widgetWithText(FilledButton, 'Add page');
    final canvasBottom = tester.getBottomRight(
      find.byKey(const ValueKey('notebook-canvas-area')),
    ).dy;
    final buttonRect = tester.getRect(addPageButton);
    expect(buttonRect.top, lessThan(canvasBottom - 22));
    expect(buttonRect.bottom, lessThanOrEqualTo(canvasBottom - 22 + 1));
    expect(buttonRect.bottom, greaterThan(canvasBottom - 80));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });

  testWidgets('quick color tap, long press and double tap stay distinct', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebook(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorToolbar(
            controller: controller,
            onInsertPressed: () {},
            onExportSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    const first = ValueKey('editor-quick-color-0');
    const second = ValueKey('editor-quick-color-1');
    const third = ValueKey('editor-quick-color-2');
    expect(find.byKey(first), findsOneWidget);
    expect(find.byKey(second), findsOneWidget);
    expect(find.byKey(third), findsOneWidget);
    final original = List<Color>.of(controller.quickColors);

    await tester.tap(find.byKey(second));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(controller.penColor, original[1]);
    expect(find.text('Pick color'), findsNothing);
    expect(controller.quickColors, original);

    await tester.longPress(find.byKey(first));
    await tester.pumpAndSettle();
    expect(find.text('Pick color'), findsOneWidget);
    expect(find.text('Palettes'), findsOneWidget);
    expect(controller.quickColors, original);

    await tester.enterText(find.byType(TextField), '#123ABC');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(controller.quickColors[0], const Color(0xFF123ABC));
    expect(controller.penColor, const Color(0xFF123ABC));
    expect(controller.quickColors[1], original[1]);
    expect(controller.quickColors[2], original[2]);

    await tester.tap(find.byKey(third));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(third));
    await tester.pumpAndSettle();
    expect(find.text('Pick color'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Pick color'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });

  testWidgets('floating toolbar overlays full-height notebook canvas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebook(),
    );

    Widget app({required bool showToolbar}) {
      return MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<EditorController>.value(value: controller),
          ],
          child: EditorScreen(showToolbar: showToolbar),
        ),
      );
    }

    await tester.pumpWidget(app(showToolbar: true));
    await tester.pump();

    const canvasKey = ValueKey('notebook-canvas-area');
    const toolbarKey = ValueKey('editor-toolbar-panel');
    const viewportKey = ValueKey('notebook-page-viewport');
    const overviewKey = ValueKey('notebook-project-overview');
    final canvas = find.byKey(canvasKey);
    final toolbar = find.byKey(toolbarKey);
    final overview = find.byKey(overviewKey);
    final canvasRect = tester.getRect(canvas);
    final toolbarRect = tester.getRect(toolbar);

    expect(
      canvasRect.top,
      closeTo(tester.getBottomLeft(find.byType(AppBar)).dy, 0.01),
    );
    expect(canvasRect.bottom, closeTo(900, 0.01));
    expect(toolbarRect.top, greaterThanOrEqualTo(canvasRect.top));
    expect(toolbarRect.bottom, lessThan(canvasRect.bottom));
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.scrolledUnderElevation, 0);
    expect(appBar.surfaceTintColor, Colors.transparent);
    final viewport = find.byKey(viewportKey);
    expect(tester.getTopLeft(viewport).dy, closeTo(canvasRect.top + 22, 0.01));
    expect(_documentTopLeft(tester).dy, closeTo(canvasRect.top + 94, 0.01));
    final scaledDocumentHeight =
        _documentLayoutSize(tester).height * _documentScale(tester);
    expect(
      tester.getSize(viewport).height,
      closeTo(scaledDocumentHeight + 72, 0.01),
    );
    expect(_documentTopLeft(tester).dy, greaterThan(toolbarRect.bottom));
    expect(tester.getTopLeft(overview).dy, closeTo(canvasRect.top + 82, 0.01));

    await tester.tap(find.byTooltip('Highlighter'));
    await tester.pump();
    expect(controller.tool, DrawingTool.highlighter);

    final panStart = tester.getTopLeft(viewport) + const Offset(160, 230);
    final firstFinger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 21,
    );
    final secondFinger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 22,
    );
    await firstFinger.down(panStart);
    await secondFinger.down(panStart + const Offset(100, 0));
    await tester.pump();
    await firstFinger.moveBy(const Offset(0, -170));
    await tester.pump();
    await secondFinger.moveBy(const Offset(0, -170));
    await tester.pump();
    expect(_documentTopLeft(tester).dy, lessThan(toolbarRect.bottom));
    final verticalDocumentPan =
        _documentTopLeft(tester).dy - tester.getTopLeft(viewport).dy;
    expect(
      tester.getSize(viewport).height,
      closeTo(
        scaledDocumentHeight +
            (verticalDocumentPan > 0 ? verticalDocumentPan : 0),
        0.01,
      ),
    );
    expect(tester.getTopLeft(viewport).dy, closeTo(canvasRect.top + 22, 0.01));
    await firstFinger.up();
    await secondFinger.up();
    await tester.pump();

    controller.setTool(DrawingTool.edit);
    preferences.previewTouchNavigationSensitivity(1.8);
    await tester.pump();
    final pageScrollViews = tester.widgetList<SingleChildScrollView>(
      find.descendant(of: canvas, matching: find.byType(SingleChildScrollView)),
    );
    expect(
      pageScrollViews.any(
        (view) =>
            view.physics is TouchNavigationScrollPhysics &&
            (view.physics! as TouchNavigationScrollPhysics).sensitivity == 1.8,
      ),
      isTrue,
    );

    await tester.binding.setSurfaceSize(const Size(1200, 420));
    await tester.pump();
    expect(
      tester.getBottomRight(overview).dy,
      lessThanOrEqualTo(tester.getBottomRight(canvas).dy),
    );

    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pump();
    await tester.pumpWidget(app(showToolbar: false));
    await tester.pump();

    expect(find.byKey(toolbarKey), findsNothing);
    expect(tester.getRect(canvas), canvasRect);
    expect(tester.getTopLeft(overview).dy, closeTo(canvasRect.top + 10, 0.01));
    expect(
      tester.getTopLeft(find.byKey(viewportKey)).dy,
      closeTo(canvasRect.top + 22, 0.01),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });
}

double _documentScale(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.byKey(const ValueKey('notebook-document-transform')),
  );
  return transform.transform.entry(0, 0);
}

double _documentTranslationX(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.byKey(const ValueKey('notebook-document-transform')),
  );
  return transform.transform.entry(0, 3);
}

Size _documentLayoutSize(WidgetTester tester) {
  return tester.getSize(
    find.byKey(const ValueKey('notebook-document-transform')),
  );
}

Size _pageViewportSize(WidgetTester tester) {
  return tester.getSize(find.byKey(const ValueKey('notebook-page-viewport')));
}

Offset _documentTopLeft(WidgetTester tester) {
  return _documentPoint(tester, Offset.zero);
}

Offset _documentTopRight(WidgetTester tester) {
  return _documentPoint(tester, Offset(_documentLayoutSize(tester).width, 0));
}

Offset _documentPoint(WidgetTester tester, Offset localPoint) {
  final finder = find.byKey(const ValueKey('notebook-document-transform'));
  final transform = tester.widget<Transform>(finder).transform;
  final layoutTopLeft = tester.getTopLeft(finder);
  return layoutTopLeft + MatrixUtils.transformPoint(transform, localPoint);
}

void _expectOverviewSideGapsEqual(WidgetTester tester) {
  final editorLeft = tester.getTopLeft(find.byType(EditorScreen)).dx;
  final overviewFinder = find.byKey(
    const ValueKey('notebook-project-overview'),
  );
  final overviewLeft = tester.getTopLeft(overviewFinder).dx;
  final overviewRight = tester.getTopRight(overviewFinder).dx;
  final viewportLeft = tester
      .getTopLeft(find.byKey(const ValueKey('notebook-page-viewport')))
      .dx;
  final leftGap = overviewLeft - editorLeft;
  final rightGap = viewportLeft - overviewRight;
  expect(leftGap, closeTo(10.0, 0.001));
  expect(rightGap, closeTo(leftGap, 0.001));
}

Notebook _notebook({int pageCount = 1}) {
  final now = DateTime(2026);
  return Notebook(
    uid: 'responsive-layout',
    title: 'Responsive layout',
    kind: NotebookKind.notebook,
    folder: 'Tests',
    createdAt: now,
    updatedAt: now,
    pages: List.generate(
      pageCount,
      (index) => NotePage(
        id: 'page-${index + 1}',
        title: 'Page ${index + 1}',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: const [],
        isBookmarked: false,
      ),
    ),
  );
}
