import 'dart:ui' show PointerDeviceKind;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

EditorController _controller(NotesDatabase database, String path) {
  final image = ImageBlock(
    id: 'page-image',
    path: path,
    ocrText: '',
    position: const Offset(790, 200),
    width: 200,
    height: 120,
  );
  final now = DateTime(2026);
  final notebook = Notebook(
    uid: 'notebook',
    title: 'Image and PDF',
    kind: NotebookKind.notebook,
    folder: '',
    createdAt: now,
    updatedAt: now,
    pages: [
      NotePage(
        id: 'page',
        title: 'Page',
        textBlocks: [],
        imageBlocks: [image],
        inkStrokes: [],
        isBookmarked: false,
      ),
    ],
  );
  return EditorController(
    repository: NotebookRepository(database),
    notebook: notebook,
  );
}

void main() {
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  for (final source in ['photo.png', 'pdf-page-1.png']) {
    testWidgets('off-page $source handle works at 125% zoom', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setActiveImageBlock('page-image');

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EditorController>.value(
            value: controller,
            child: Scaffold(
              body: SizedBox(
                width: 1280,
                height: 800,
                child: Stack(
                  children: [
                    Consumer<EditorController>(
                      builder: (context, editor, _) =>
                          ActiveImageTransformHud(
                            controller: editor,
                            block: editor.pages.single.imageBlocks.single,
                            pageIndex: 0,
                            worldOrigin: Offset.zero,
                            interactionEnabled: true,
                            viewportScale: 1.25,
                            viewportOffset: const Offset(20, 0),
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final resize = find.byKey(
        const ValueKey('object-transform-bottomRight-hit-zone'),
      );
      expect(resize, findsOneWidget);
      final handle = tester.getCenter(resize);
      expect(handle.dx, greaterThan(820 * 1.25 + 20));

      final pointer = await tester.startGesture(
        handle,
        kind: PointerDeviceKind.touch,
      );
      await pointer.moveBy(const Offset(35, 20));
      await tester.pump();
      await pointer.up();
      await tester.pump();

      final resized = controller.pages.single.imageBlocks.single;
      expect(resized.width, greaterThan(200));
      expect(resized.height, greaterThan(120));
      expect(resized.width / resized.height, closeTo(200 / 120, 0.01));

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    });

    testWidgets('$source pinches inside the real notebook viewport', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      final preferences = AppPreferencesController();
      final controller = _controller(database, source);
      controller.setTool(DrawingTool.edit);
      controller.setActiveImageBlock('page-image');

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppPreferencesController>.value(
                value: preferences,
              ),
              ChangeNotifierProvider<EditorController>.value(
                value: controller,
              ),
            ],
            child: const EditorScreen(showToolbar: false),
          ),
        ),
      );
      await tester.pump();
      final viewport = find.byKey(const ValueKey('notebook-page-viewport'));
      final transform = tester.widget<Transform>(
        find.byKey(const ValueKey('notebook-document-transform')),
      );
      final topLeft = tester.getTopLeft(viewport);
      final firstPosition = topLeft +
          MatrixUtils.transformPoint(
            transform.transform,
            const Offset(850, 260),
          );
      final secondPosition = topLeft +
          MatrixUtils.transformPoint(
            transform.transform,
            const Offset(930, 260),
          );
      final originalDocumentScale = transform.transform.entry(0, 0);

      final first = await tester.startGesture(
        firstPosition,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(controller.isObjectTransformActive, isTrue);
      final second = await tester.startGesture(
        secondPosition,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      await first.moveBy(const Offset(-12, 0));
      await second.moveBy(const Offset(12, 0));
      await tester.pump();

      expect(
        controller.imageTransformPreview.value?.width,
        greaterThan(200),
      );
      expect(controller.pages.single.imageBlocks.single.width, 200);
      final newDocumentScale = tester
          .widget<Transform>(
            find.byKey(const ValueKey('notebook-document-transform')),
          )
          .transform
          .entry(0, 0);
      expect(newDocumentScale, closeTo(originalDocumentScale, 0.0001));
      await first.up();
      await second.up();
      await tester.pump();
      expect(
        controller.pages.single.imageBlocks.single.width,
        greaterThan(200),
      );
      expect(controller.imageTransformPreview.value, isNull);
      controller.undo();
      expect(controller.pages.single.imageBlocks.single.width, 200);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      preferences.dispose();
      await database.close();
    });

    testWidgets('$source repeated pinch is bounded and undoable', (
      tester,
    ) async {
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setActiveImageBlock('page-image');
      controller.startPinchToScaleActiveImage();
      for (var i = 0; i < 60; i++) {
        controller.updatePinchToScaleActiveImage(
          1.05,
          const Offset(0.5, -0.25),
        );
      }
      controller.endPinchToScaleActiveImage();
      var image = controller.pages.single.imageBlocks.single;
      expect(image.width, inInclusiveRange(80, 4096));
      expect(image.height, inInclusiveRange(60, 4096));
      expect(image.width / image.height, closeTo(200 / 120, 0.0001));

      controller.undo();
      image = controller.pages.single.imageBlocks.single;
      expect(image.width, 200);
      expect(image.height, 120);
      expect(image.position, const Offset(790, 200));

      controller.redo();
      image = controller.pages.single.imageBlocks.single;
      expect(image.width, greaterThan(200));
      controller.startPinchToScaleActiveImage();
      controller.updatePinchToScaleActiveImage(0.00001, Offset.zero);
      controller.endPinchToScaleActiveImage();
      image = controller.pages.single.imageBlocks.single;
      expect(image.width, greaterThanOrEqualTo(80));
      expect(image.height, greaterThanOrEqualTo(60));

      controller.dispose();
      await database.close();
    });
    testWidgets('$source two touch contacts resize the selected object', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setActiveImageBlock('page-image');
      var viewportNavigationStarts = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EditorController>.value(
            value: controller,
            child: Scaffold(
              body: SizedBox(
                width: 1280,
                height: 800,
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    if (event.kind == PointerDeviceKind.touch &&
                        !controller.isObjectTransformActive) {
                      viewportNavigationStarts++;
                    }
                  },
                  child: Stack(
                    children: [
                      Consumer<EditorController>(
                        builder: (context, editor, _) =>
                            ActiveImageTransformHud(
                              controller: editor,
                              block: editor.pages.single.imageBlocks.single,
                              pageIndex: 0,
                              worldOrigin: Offset.zero,
                              interactionEnabled: true,
                              viewportScale: 1.25,
                              viewportOffset: const Offset(20, 0),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final first = await tester.startGesture(
        const Offset(1100, 325),
        kind: PointerDeviceKind.touch,
      );
      expect(controller.isObjectTransformActive, isTrue);
      final second = await tester.startGesture(
        const Offset(1160, 325),
        kind: PointerDeviceKind.touch,
      );
      expect(viewportNavigationStarts, 0);
      await first.moveBy(const Offset(-15, 0));
      await second.moveBy(const Offset(15, 0));
      await tester.pump();
      final preview = controller.imageTransformPreview.value;
      expect(preview, isNotNull);
      expect(preview!.width, greaterThan(200));
      expect(preview.height, greaterThan(120));
      expect(preview.width / preview.height, closeTo(5 / 3, 0.0001));
      expect(controller.pages.single.imageBlocks.single.width, 200);

      await first.up();
      await second.up();
      await tester.pump();
      final enlarged = controller.pages.single.imageBlocks.single;
      expect(enlarged.width, greaterThan(200));
      expect(controller.imageTransformPreview.value, isNull);
      expect(controller.isObjectTransformActive, isFalse);
      controller.undo();
      var restored = controller.pages.single.imageBlocks.single;
      expect(restored.width, 200);
      expect(restored.height, 120);
      expect(restored.position, const Offset(790, 200));
      controller.redo();
      restored = controller.pages.single.imageBlocks.single;
      expect(restored.width, closeTo(enlarged.width, 0.001));

      final shrinkFirst = await tester.startGesture(
        const Offset(1100, 325),
        kind: PointerDeviceKind.touch,
      );
      final shrinkSecond = await tester.startGesture(
        const Offset(1160, 325),
        kind: PointerDeviceKind.touch,
      );
      await shrinkFirst.moveBy(const Offset(12, 0));
      await shrinkSecond.moveBy(const Offset(-12, 0));
      await shrinkFirst.up();
      await shrinkSecond.up();
      await tester.pump();
      final reduced = controller.pages.single.imageBlocks.single;
      expect(reduced.width, lessThan(enlarged.width));
      expect(reduced.height, lessThan(enlarged.height));
      expect(viewportNavigationStarts, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    });

    testWidgets('$source canceled single-touch drag restores original', (
      tester,
    ) async {
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setActiveImageBlock('page-image');
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EditorController>.value(
            value: controller,
            child: Scaffold(
              body: Stack(
                children: [
                  Consumer<EditorController>(
                    builder: (context, editor, _) =>
                        ActiveImageTransformHud(
                          controller: editor,
                          block: editor.pages.single.imageBlocks.single,
                          pageIndex: 0,
                          worldOrigin: Offset.zero,
                          interactionEnabled: true,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final pointer = await tester.startGesture(
        const Offset(890, 260),
        kind: PointerDeviceKind.touch,
      );
      await pointer.moveBy(const Offset(20, 12));
      await tester.pump();
      expect(
        controller.imageTransformPreview.value?.position,
        isNot(const Offset(790, 200)),
      );
      expect(
        controller.pages.single.imageBlocks.single.position,
        const Offset(790, 200),
      );
      await pointer.cancel();
      await tester.pump();
      expect(
        controller.pages.single.imageBlocks.single.position,
        const Offset(790, 200),
      );
      expect(controller.isObjectTransformActive, isFalse);
      expect(controller.imageTransformPreview.value, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    });

    testWidgets('$source keeps frame alive during sustained pinch', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setActiveImageBlock('page-image');
      var rootNotifications = 0;
      controller.addListener(() => rootNotifications++);
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EditorController>.value(
            value: controller,
            child: Scaffold(
              body: Stack(
                children: [
                  Consumer<EditorController>(
                    builder: (context, editor, _) =>
                        ActiveImageTransformHud(
                          controller: editor,
                          block: editor.pages.single.imageBlocks.single,
                          pageIndex: 0,
                          worldOrigin: Offset.zero,
                          interactionEnabled: true,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final first = await tester.startGesture(
        const Offset(840, 260),
        kind: PointerDeviceKind.touch,
      );
      final second = await tester.startGesture(
        const Offset(920, 260),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      final countAfterStart = rootNotifications;
      for (var i = 0; i < 35; i++) {
        await first.moveBy(const Offset(1, 0));
        await second.moveBy(const Offset(-1, 0));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(controller.isObjectTransformActive, isTrue);
        expect(rootNotifications, countAfterStart);
        expect(controller.pages.single.imageBlocks.single.width, 200);
      }
      expect(controller.imageTransformPreview.value?.width, lessThan(200));
      await first.up();
      await second.up();
      await tester.pump();
      expect(controller.pages.single.imageBlocks.single.width, lessThan(200));
      expect(controller.imageTransformPreview.value, isNull);
      expect(controller.isObjectTransformActive, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    });

    testWidgets('$source disposes safely during active multitouch', (
      tester,
    ) async {
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setActiveImageBlock('page-image');
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EditorController>.value(
            value: controller,
            child: Scaffold(
              body: Stack(
                children: [
                  ActiveImageTransformHud(
                    controller: controller,
                    block: controller.pages.single.imageBlocks.single,
                    pageIndex: 0,
                    worldOrigin: Offset.zero,
                    interactionEnabled: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final first = await tester.startGesture(
        const Offset(840, 260),
        kind: PointerDeviceKind.touch,
      );
      final second = await tester.startGesture(
        const Offset(920, 260),
        kind: PointerDeviceKind.touch,
      );
      await first.moveBy(const Offset(10, 0));
      await tester.pump();
      expect(controller.isObjectTransformActive, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(controller.isObjectTransformActive, isFalse);
      expect(controller.imageTransformPreview.value, isNull);
      await first.moveBy(const Offset(-8, 0));
      await second.moveBy(const Offset(8, 0));
      await first.up();
      await second.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(controller.pages.single.imageBlocks.single.width, 200);

      controller.dispose();
      await database.close();
    });
  }
}
