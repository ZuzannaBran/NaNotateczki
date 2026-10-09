import 'dart:ui' show PointerDeviceKind;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_metrics.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/presentation/interaction/notebook_overview_navigation.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  test('minimap scroll offset changes which document point is selected', () {
    const scale = 84 / 820;
    const docSize = Size(820, 12000);
    final point = NotebookOverviewNavigation.documentPoint(
      localPoint: const Offset(42, 150),
      scrollOffset: 240,
      mapScale: scale,
      documentSize: docSize,
    );
    expect(point.dx, 410);
    expect(point.dy, closeTo(390 / scale, 0.001));

    final clipped = NotebookOverviewNavigation.documentPoint(
      localPoint: const Offset(-20, 9999),
      scrollOffset: 0,
      mapScale: scale,
      documentSize: docSize,
    );
    expect(clipped, const Offset(0, 12000));
  });

  test('navigation preserves zoom and centers a point when scroll clamps', () {
    const world = Offset(410, 2300);
    const viewport = Size(500, 700);
    const scale = 1.5;
    final target = NotebookOverviewNavigation.viewportTarget(
      documentPoint: world,
      viewportSize: viewport,
      effectiveScale: scale,
      currentPanY: 72,
      topPadding: 22,
      maxScrollOffset: 2200,
    );
    expect(target.scrollOffset, 2200);
    expect(
      (viewport.width / 2 - target.pan.dx) / scale,
      closeTo(world.dx, 0.001),
    );
    expect(
      (target.scrollOffset +
              viewport.height / 2 -
              22 -
              target.pan.dy) /
          scale,
      closeTo(world.dy, 0.001),
    );
  });

  testWidgets('tapping overview moves the notebook to the selected page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebook(3),
    );

    await tester.pumpWidget(_app(controller, preferences));
    await tester.pump();

    const tapSurfaceKey = ValueKey('notebook-overview-tap-surface');
    expect(find.byKey(tapSurfaceKey), findsOneWidget);
    final mapTopLeft = tester.getTopLeft(find.byKey(tapSurfaceKey));
    const mapScale = 84 / 820;
    const pageHeight = 820 * AppMetrics.a4HeightRatio;
    final targetY = (pageHeight * 1.5 + 26) * mapScale;

    await tester.tapAt(mapTopLeft + Offset(42, targetY));
    await tester.pumpAndSettle();
    expect(controller.currentPageIndex, 1);
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('notebook-document-scroll')),
    );
    final secondPageOffset = scroll.controller!.offset;
    expect(secondPageOffset, greaterThan(200));

    await tester.tapAt(mapTopLeft + const Offset(42, 32));
    await tester.pumpAndSettle();
    expect(controller.currentPageIndex, 0);
    expect(scroll.controller!.offset, lessThan(secondPageOffset));

    controller.beginObjectTransform();
    await tester.pump();
    await tester.tapAt(mapTopLeft + Offset(42, targetY));
    await tester.pump();
    expect(controller.currentPageIndex, 0);
    controller.endObjectTransform();

    await _dispose(tester, controller, preferences, database);
  });

  testWidgets('scrolling minimap does not navigate, tapping after does', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebook(12),
    );
    await tester.pumpWidget(_app(controller, preferences));
    await tester.pump();

    final overview = find.byKey(
      const ValueKey('notebook-overview-tap-surface'),
    );
    final minimap = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('notebook-overview-scroll')),
    );
    final firstPage = controller.currentPageIndex;

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.touch,
    );
    await gesture.down(tester.getCenter(overview));
    await gesture.moveBy(const Offset(0, -260));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final mapScrollOffset = minimap.controller!.offset;
    expect(mapScrollOffset, greaterThan(20));
    expect(controller.currentPageIndex, firstPage);

    const clickLocal = Offset(42, 130);
    final expectedIndex =
        (((mapScrollOffset + clickLocal.dy) / (84 / 820)) /
                (820 * AppMetrics.a4HeightRatio + 26))
            .floor()
            .clamp(0, controller.pages.length - 1);
    await tester.tapAt(tester.getTopLeft(overview) + clickLocal);
    await tester.pumpAndSettle();

    expect(controller.currentPageIndex, expectedIndex);
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('notebook-document-scroll')),
          )
          .controller!
          .offset,
      greaterThan(100),
    );

    await _dispose(tester, controller, preferences, database);
  });
}

Widget _app(
  EditorController controller,
  AppPreferencesController preferences,
) {
  return MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<AppPreferencesController>.value(
          value: preferences,
        ),
        ChangeNotifierProvider<EditorController>.value(value: controller),
      ],
      child: const EditorScreen(),
    ),
  );
}

Notebook _notebook(int count) {
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

Future<void> _dispose(
  WidgetTester tester,
  EditorController controller,
  AppPreferencesController preferences,
  NotesDatabase database,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  preferences.dispose();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await database.close();
}
