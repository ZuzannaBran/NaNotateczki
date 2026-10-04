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
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  testWidgets('narrow window keeps page clear of overview and right aligned', (
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
    expect(
      _documentScale(tester),
      closeTo((1000 - 106 - 56 - 56) / 820, 0.001),
    );
    final wideRightMargin = 1000 - _documentTopRight(tester).dx;
    expect(wideRightMargin, closeTo(56.0, 0.001));
    _expectSymmetricHorizontalMargins(tester);

    await tester.binding.setSurfaceSize(const Size(500, 900));
    await tester.pump();

    expect(
      controller.layoutPageSize,
      const Size(logicalPageWidth, logicalPageWidth * AppMetrics.a4HeightRatio),
    );
    expect(_documentLayoutSize(tester).width, logicalPageWidth);
    expect(
      _documentScale(tester),
      closeTo((500 - 106 - 56 - 56) / 820, 0.001),
    );
    final narrowRightMargin = 500 - _documentTopRight(tester).dx;
    expect(narrowRightMargin, closeTo(wideRightMargin, 0.001));
    _expectSymmetricHorizontalMargins(tester);
    expect(find.text('Widen the window to edit this notebook.'), findsNothing);

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

Size _documentLayoutSize(WidgetTester tester) {
  return tester.getSize(
    find.byKey(const ValueKey('notebook-document-transform')),
  );
}

Offset _documentTopRight(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('notebook-document-transform'));
  final transform = tester.widget<Transform>(finder).transform;
  final layoutTopLeft = tester.getTopLeft(finder);
  final layoutSize = tester.getSize(finder);
  return layoutTopLeft +
      MatrixUtils.transformPoint(transform, Offset(layoutSize.width, 0));
}

void _expectSymmetricHorizontalMargins(WidgetTester tester) {
  final documentLeft = tester
      .getTopLeft(find.byKey(const ValueKey('notebook-document-transform')))
      .dx;
  final overviewRight = tester
      .getTopRight(find.byKey(const ValueKey('notebook-project-overview')))
      .dx;
  final viewportRight = tester.getTopRight(find.byType(EditorScreen)).dx;
  final documentRight = _documentTopRight(tester).dx;
  final leftGap = documentLeft - overviewRight;
  final rightGap = viewportRight - documentRight;
  expect(leftGap, closeTo(rightGap, 0.001));
  expect(rightGap, closeTo(56.0, 0.001));
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
        indexTabs: const [],
      ),
    ],
  );
}