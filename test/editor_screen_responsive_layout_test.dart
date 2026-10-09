import 'dart:ui' show PointerDeviceKind;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_metrics.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
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
    expect(_documentScale(tester), closeTo((500 - 106 - 10 - 56) / 820, 0.001));
    final narrowRightMargin = 500 - _documentTopRight(tester).dx;
    expect(narrowRightMargin, closeTo(wideViewportRightMargin, 0.001));
    expect(_pageViewportSize(tester).width, closeTo(328.0, 0.001));
    _expectOverviewSideGapsEqual(tester);
    expect(find.text('Widen the window to edit this notebook.'), findsNothing);

    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pump();

    expect(_documentScale(tester), closeTo(1.0, 0.001));
    expect(_pageViewportSize(tester).width, closeTo(928.0, 0.001));
    expect(_documentTranslationX(tester), closeTo(0.0, 0.001));

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
    expect(translatedX, greaterThan(0.0));
    expect(translatedX, lessThanOrEqualTo(108.0));

    await firstFinger.up();
    await secondFinger.up();
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
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
    final page = find.byKey(const ValueKey('notebook-document-transform'));
    expect(
      tester.getTopLeft(viewport).dy,
      closeTo(canvasRect.top + 22, 0.01),
    );
    expect(
      tester.getTopLeft(page).dy,
      closeTo(canvasRect.top + 94, 0.01),
    );
    final scaledDocumentHeight =
        _documentLayoutSize(tester).height * _documentScale(tester);
    expect(
      tester.getSize(viewport).height,
      closeTo(scaledDocumentHeight + 72, 0.01),
    );
    expect(tester.getTopLeft(page).dy, greaterThan(toolbarRect.bottom));
    expect(
      tester.getTopLeft(overview).dy,
      closeTo(canvasRect.top + 82, 0.01),
    );

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
    expect(tester.getTopLeft(page).dy, lessThan(toolbarRect.bottom));
    final verticalDocumentPan =
        tester.getTopLeft(page).dy - tester.getTopLeft(viewport).dy;
    expect(
      tester.getSize(viewport).height,
      closeTo(
        scaledDocumentHeight +
            (verticalDocumentPan > 0 ? verticalDocumentPan : 0),
        0.01,
      ),
    );
    expect(
      tester.getTopLeft(viewport).dy,
      closeTo(canvasRect.top + 22, 0.01),
    );
    await firstFinger.up();
    await secondFinger.up();
    await tester.pump();

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
    expect(
      tester.getTopLeft(overview).dy,
      closeTo(canvasRect.top + 10, 0.01),
    );
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

Offset _documentTopRight(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('notebook-document-transform'));
  final transform = tester.widget<Transform>(finder).transform;
  final layoutTopLeft = tester.getTopLeft(finder);
  final layoutSize = tester.getSize(finder);
  return layoutTopLeft +
      MatrixUtils.transformPoint(transform, Offset(layoutSize.width, 0));
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

Notebook _notebook() {
  final now = DateTime(2026);
  return Notebook(
    uid: 'responsive-layout',
    title: 'Responsive layout',
    kind: NotebookKind.notebook,
    folder: 'Tests',
    createdAt: now,
    updatedAt: now,
    pages: [
      NotePage(
        id: 'page-1',
        title: 'Page 1',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: const [],
        isBookmarked: false,
      ),
    ],
  );
}
