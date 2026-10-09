import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_metrics.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/presentation/interaction/'
    'notebook_overview_navigation.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();

  test('minimap positions map to clamped document coordinates', () {
    const docSize = Size(820, 2800);
    const mapScale = 84 / 820;

    expect(
      NotebookOverviewNavigation.documentPoint(
        mapPoint: const Offset(42, 140),
        mapScale: mapScale,
        documentSize: docSize,
      ),
      Offset(410, 140 / mapScale),
    );
    expect(
      NotebookOverviewNavigation.documentPoint(
        mapPoint: const Offset(-30, 500),
        mapScale: mapScale,
        documentSize: docSize,
      ),
      const Offset(0, 2800),
    );
    expect(
      NotebookOverviewNavigation.documentPoint(
        mapPoint: const Offset(42, 140),
        mapScale: mapScale,
        mapScrollOffset: 100,
        documentSize: docSize,
      ),
      Offset(410, 240 / mapScale),
    );
  });

  test('minimap navigation centers the tapped point without changing zoom', () {
    const viewport = Size(500, 700);
    const clickedPoint = Offset(410, 1900);
    const scale = 1.5;
    final target = NotebookOverviewNavigation.viewportTarget(
      documentPoint: clickedPoint,
      viewportSize: viewport,
      effectiveScale: scale,
      maxScrollOffset: 2200,
      topPadding: 22,
    );

    expect(target.scrollOffset, 2200);
    final centeredWorldPoint = Offset(
      (viewport.width / 2 - target.pan.dx) / scale,
      (target.scrollOffset - 22 + viewport.height / 2 - target.pan.dy) /
          scale,
    );
    expect(centeredWorldPoint.dx, closeTo(clickedPoint.dx, 0.0001));
    expect(centeredWorldPoint.dy, closeTo(clickedPoint.dy, 0.0001));
  });

  testWidgets('overview taps switch notebook pages and scroll to their area', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebookWithThreePages(),
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

    final minimap = find.byKey(
      const ValueKey('notebook-overview-tap-surface'),
    );
    expect(minimap, findsOneWidget);

    final mapTopLeft = tester.getTopLeft(minimap);
    const mapScale = 84 / 820;
    const pageHeight = 820 * AppMetrics.a4HeightRatio;
    const pageGap = 26.0;
    final secondPageCenter = Offset(
      42,
      (pageHeight * 1.5 + pageGap) * mapScale,
    );
    await tester.tapAt(mapTopLeft + secondPageCenter);
    await tester.pumpAndSettle();

    expect(controller.currentPageIndex, 1);
    final pageScroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('notebook-document-scroll')),
    );
    expect(pageScroll.controller!.offset, greaterThan(50));

    await tester.tapAt(mapTopLeft + Offset(42, pageHeight * mapScale * 0.25));
    await tester.pumpAndSettle();
    expect(controller.currentPageIndex, 0);
    expect(pageScroll.controller!.offset, closeTo(0, 0.5));

    controller.beginObjectTransform();
    await tester.pump();
    final thirdPageCenter = Offset(
      42,
      (pageHeight * 2.5 + pageGap * 2) * mapScale,
    );
    await tester.tapAt(mapTopLeft + thirdPageCenter);
    await tester.pumpAndSettle();
    expect(controller.currentPageIndex, 0);
    controller.endObjectTransform();

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });

  testWidgets('overview navigates using its own scroll offset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebookWithPages(12),
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

    final overviewFinder = find.byKey(
      const ValueKey('notebook-overview-tap-surface'),
    );
    final minimapScroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('notebook-overview-scroll')),
    );
    await tester.drag(overviewFinder, const Offset(0, -280));
    await tester.pumpAndSettle();
    final overviewOffset = minimapScroll.controller!.offset;
    expect(overviewOffset, greaterThan(50));

    const tapPoint = Offset(42, 200);
    const mapScale = 84 / 820;
    const pageHeight = 820 * AppMetrics.a4HeightRatio;
    const pageGap = 26.0;
    final expectedPage = (((overviewOffset + tapPoint.dy) / mapScale) /
            (pageHeight + pageGap))
        .floor()
        .clamp(0, controller.pages.length - 1);

    await tester.tapAt(tester.getTopLeft(overviewFinder) + tapPoint);
    await tester.pumpAndSettle();
    expect(controller.currentPageIndex, expectedPage);
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('notebook-document-scroll')),
          )
          .controller!
          .offset,
      greaterThan(100),
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

Notebook _notebookWithThreePages() => _notebookWithPages(3);

Notebook _notebookWithPages(int count) {
  final now = DateTime(2026);
  return Notebook(
    uid: 'overview-navigation',
    title: 'Overview navigation',
    kind: NotebookKind.notebook,
    folder: 'Tests',
    createdAt: now,
    updatedAt: now,
    pages: List.generate(
      count,
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
