import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/board/presentation/board_screen.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/input_mode.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

Future<void> _drawPointer(
  WidgetTester tester,
  Offset start, {
  required int pointer,
  required PointerDeviceKind kind,
  double radiusMajor = 34,
  double radiusMinor = 24,
}) async {
  await tester.sendEventToBinding(
    PointerDownEvent(
      pointer: pointer,
      kind: kind,
      position: start,
      buttons: kPrimaryButton,
      radiusMajor: radiusMajor,
      radiusMinor: radiusMinor,
    ),
  );
  await tester.pump();
  final middle = start + const Offset(18, 8);
  await tester.sendEventToBinding(
    PointerMoveEvent(
      pointer: pointer,
      kind: kind,
      position: middle,
      delta: middle - start,
      buttons: kPrimaryButton,
      radiusMajor: radiusMajor,
      radiusMinor: radiusMinor,
    ),
  );
  await tester.pump();
  final end = middle + const Offset(24, 10);
  await tester.sendEventToBinding(
    PointerMoveEvent(
      pointer: pointer,
      kind: kind,
      position: end,
      delta: end - middle,
      buttons: kPrimaryButton,
      radiusMajor: radiusMajor,
      radiusMinor: radiusMinor,
    ),
  );
  await tester.pump();
  await tester.sendEventToBinding(
    PointerUpEvent(
      pointer: pointer,
      kind: kind,
      position: end,
      radiusMajor: radiusMajor,
      radiusMinor: radiusMinor,
    ),
  );
  await tester.pump();
}

Future<void> _touchDown(
  WidgetTester tester,
  Offset position,
  int pointer,
) async {
  await tester.sendEventToBinding(
    PointerDownEvent(
      pointer: pointer,
      kind: PointerDeviceKind.touch,
      position: position,
      buttons: kPrimaryButton,
      radiusMajor: 34,
      radiusMinor: 24,
    ),
  );
}

Future<void> _touchUp(WidgetTester tester, Offset position, int pointer) async {
  await tester.sendEventToBinding(
    PointerUpEvent(
      pointer: pointer,
      kind: PointerDeviceKind.touch,
      position: position,
    ),
  );
}

void main() {
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  for (final kind in [NotebookKind.notebook, NotebookKind.board]) {
    testWidgets('Android-sized finger draws in Off on phone $kind, '
        'On blocks touch but accepts pen', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final database = NotesDatabase(NativeDatabase.memory());
      final repository = NotebookRepository(database);
      final preferences = AppPreferencesController();
      final now = DateTime(2026);
      final notebook = Notebook(
        uid: 'phone-touch-${kind.name}',
        title: 'Finger writing',
        kind: kind,
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
      final controller = EditorController(
        repository: repository,
        notebook: notebook,
      );
      controller.setTool(DrawingTool.pen);
      controller.setPointerInputMode(PointerInputMode.off);
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<EditorController>.value(value: controller),
              ChangeNotifierProvider<AppPreferencesController>.value(
                value: preferences,
              ),
            ],
            child: kind == NotebookKind.board
                ? const BoardScreen(showToolbar: false)
                : const EditorScreen(showToolbar: false),
          ),
        ),
      );
      await tester.pump();

      final drawingPoint = kind == NotebookKind.board
          ? tester.getCenter(find.byKey(const ValueKey('board-canvas-area'))) -
                const Offset(50, 50)
          : tester.getTopLeft(
                  find.byKey(const ValueKey('notebook-page-viewport')),
                ) +
                const Offset(100, 150);

      await _drawPointer(
        tester,
        drawingPoint,
        pointer: 101,
        kind: PointerDeviceKind.touch,
      );
      expect(
        controller.currentPage.inkStrokes,
        hasLength(1),
        reason: 'A normal Android finger has a device-dependent touch radius',
      );
      expect(
        controller.currentPage.inkStrokes.single.points.length,
        greaterThan(1),
      );

      controller.setPointerInputMode(PointerInputMode.on);
      await tester.pump();
      await _drawPointer(
        tester,
        drawingPoint + const Offset(0, 55),
        pointer: 102,
        kind: PointerDeviceKind.touch,
      );
      expect(controller.currentPage.inkStrokes, hasLength(1));

      await _drawPointer(
        tester,
        drawingPoint + const Offset(0, 90),
        pointer: 103,
        kind: PointerDeviceKind.stylus,
      );
      expect(controller.currentPage.inkStrokes, hasLength(2));

      controller.setPointerInputMode(PointerInputMode.off);
      await tester.pump();
      final palmPosition = drawingPoint + const Offset(0, 135);
      await _touchDown(tester, palmPosition, 104);
      await _touchDown(tester, palmPosition + const Offset(60, 0), 105);
      await tester.pump();
      await _touchUp(tester, palmPosition, 104);
      await _touchUp(tester, palmPosition + const Offset(60, 0), 105);
      await tester.pump();
      expect(
        controller.currentPage.inkStrokes,
        hasLength(2),
        reason: 'Two stationary contacts must not create palm dots',
      );

      await _drawPointer(
        tester,
        drawingPoint + const Offset(0, 170),
        pointer: 106,
        kind: PointerDeviceKind.touch,
      );
      expect(
        controller.currentPage.inkStrokes,
        hasLength(3),
        reason: 'Touch drawing must resume after a two-finger gesture',
      );

      final restingPalm = drawingPoint + const Offset(60, 180);
      await _touchDown(tester, restingPalm, 107);
      await tester.pump();
      await _drawPointer(
        tester,
        drawingPoint + const Offset(0, 210),
        pointer: 108,
        kind: PointerDeviceKind.stylus,
        radiusMajor: 1,
        radiusMinor: 1,
      );
      expect(
        controller.currentPage.inkStrokes,
        hasLength(4),
        reason: 'A stylus must take priority if the palm lands first',
      );
      await _touchUp(tester, restingPalm, 107);
      await tester.pump();
      expect(controller.currentPage.inkStrokes, hasLength(4));

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      preferences.dispose();
      await repository.waitForPendingSaves();
      await database.close();
    });
  }
}
