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
import 'package:program/features/editor/state/input_mode.dart';
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
      controller.setTool(DrawingTool.edit);
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
                      builder: (context, editor, _) => ActiveImageTransformHud(
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

    testWidgets('$source side handle crops without scaling', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setTool(DrawingTool.edit);
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

      final handle = find.byKey(
        const ValueKey('object-transform-right-hit-zone'),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.touch,
      );
      await gesture.moveBy(const Offset(-30, 0));
      await gesture.up();
      await tester.pump();

      final cropped = controller.pages.single.imageBlocks.single;
      expect(cropped.width, 200);
      expect(cropped.height, 120);
      expect(cropped.cropRight, closeTo(0.85, 0.001));
      controller.undo();
      expect(controller.pages.single.imageBlocks.single.cropRight, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await database.close();
    });

    testWidgets('$source two fingers keep the selected canvas frozen', (
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
              ChangeNotifierProvider<EditorController>.value(value: controller),
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
      final firstPosition =
          topLeft +
          MatrixUtils.transformPoint(
            transform.transform,
            const Offset(850, 260),
          );
      final secondPosition =
          topLeft +
          MatrixUtils.transformPoint(
            transform.transform,
            const Offset(850, 340),
          );
      expect(tester.getRect(viewport).contains(secondPosition), isTrue);
      final originalDocumentScale = transform.transform.entry(0, 0);

      final first = await tester.startGesture(
        firstPosition,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(controller.isObjectTransformActive, isFalse);
      final second = await tester.startGesture(
        secondPosition,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(controller.isObjectTransformActive, isFalse);
      await first.moveBy(const Offset(0, -12));
      await second.moveBy(const Offset(0, 12));
      await tester.pump();

      expect(controller.imageTransformPreview.value, isNull);
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
      expect(controller.pages.single.imageBlocks.single.width, 200);
      expect(controller.imageTransformPreview.value, isNull);
      expect(controller.activeImageBlockId, 'page-image');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
      controller.dispose();
      preferences.dispose();
      await database.close();
    });

    testWidgets('$source viewport zoom preserves selected object geometry', (
      tester,
    ) async {
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setTool(DrawingTool.edit);
      controller.setActiveImageBlock('page-image');
      final originalScale = controller.viewScale;
      controller.zoomBy(1.5, focalPoint: const Offset(400, 300));
      final image = controller.pages.single.imageBlocks.single;
      expect(image.width, 200);
      expect(image.height, 120);
      expect(image.position, const Offset(790, 200));
      expect(controller.activeImageBlockId, 'page-image');
      expect(controller.viewScale, originalScale);

      controller.dispose();
      await database.close();
    });
    testWidgets('$source HUD delegates two touch contacts to the viewport', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setTool(DrawingTool.edit);
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
      expect(controller.isObjectTransformActive, isFalse);
      final second = await tester.startGesture(
        const Offset(1160, 325),
        kind: PointerDeviceKind.touch,
      );
      expect(controller.isObjectTransformActive, isFalse);
      expect(viewportNavigationStarts, 2);
      await first.moveBy(const Offset(-15, 0));
      await second.moveBy(const Offset(15, 0));
      await tester.pump();
      expect(controller.imageTransformPreview.value, isNull);
      expect(controller.pages.single.imageBlocks.single.width, 200);

      await first.up();
      await second.up();
      await tester.pump();
      final enlarged = controller.pages.single.imageBlocks.single;
      expect(enlarged.width, 200);
      expect(controller.imageTransformPreview.value, isNull);
      expect(controller.isObjectTransformActive, isFalse);
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
      expect(reduced.width, enlarged.width);
      expect(reduced.height, enlarged.height);
      expect(viewportNavigationStarts, 4);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
      controller.dispose();
      await database.close();
    });

    testWidgets('$source one-finger body drag cancels without commit', (
      tester,
    ) async {
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setPointerInputMode(PointerInputMode.on);
      controller.setTool(DrawingTool.edit);
      controller.setActiveImageBlock('page-image');
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EditorController>.value(
            value: controller,
            child: Scaffold(
              body: Stack(
                children: [
                  Consumer<EditorController>(
                    builder: (context, editor, _) => ActiveImageTransformHud(
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
    testWidgets('$source HUD stays passive during sustained viewport pinch', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setTool(DrawingTool.edit);
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
                    builder: (context, editor, _) => ActiveImageTransformHud(
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
        expect(controller.isObjectTransformActive, isFalse);
        expect(rootNotifications, countAfterStart);
        expect(controller.pages.single.imageBlocks.single.width, 200);
      }
      expect(controller.imageTransformPreview.value, isNull);
      await first.up();
      await second.up();
      await tester.pump();
      expect(controller.pages.single.imageBlocks.single.width, 200);
      expect(controller.imageTransformPreview.value, isNull);
      expect(controller.isObjectTransformActive, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
      controller.dispose();
      await database.close();
    });

    testWidgets('$source disposes safely during delegated multitouch', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      final controller = _controller(database, source);
      controller.setTool(DrawingTool.edit);
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
      expect(controller.isObjectTransformActive, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(controller.isObjectTransformActive, isFalse);
      expect(controller.imageTransformPreview.value, isNull);
      await first.moveBy(const Offset(-8, 0));
      await second.moveBy(const Offset(8, 0));
      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(controller.pages.single.imageBlocks.single.width, 200);

      controller.dispose();
      await database.close();
    });
  }

  testWidgets('image body drag works with either finger drawing preference', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1300, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = _controller(database, 'photo.png');
    controller.setTool(DrawingTool.edit);
    controller.setActiveImageBlock('page-image');

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<EditorController>.value(value: controller),
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
    final imagePosition =
        tester.getTopLeft(viewport) +
        MatrixUtils.transformPoint(transform.transform, const Offset(890, 260));

    var gesture = await tester.startGesture(
      imagePosition,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(30, 20));
    await gesture.up();
    await tester.pump();
    final draggedWithFingerWriting =
        controller.pages.single.imageBlocks.single.position;
    expect(draggedWithFingerWriting.dx, greaterThan(790));
    expect(draggedWithFingerWriting.dy, greaterThan(200));

    controller.setPointerInputMode(PointerInputMode.on);
    await tester.pump();
    gesture = await tester.startGesture(
      imagePosition,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(30, 20));
    await gesture.up();
    await tester.pump();
    final dragged = controller.pages.single.imageBlocks.single.position;
    expect(dragged.dx, greaterThan(draggedWithFingerWriting.dx));
    expect(dragged.dy, greaterThan(draggedWithFingerWriting.dy));

    controller.setPointerInputMode(PointerInputMode.off);
    await tester.pump();
    gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('object-transform-move-hit-zone')),
      ),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(20, 10));
    await gesture.up();
    await tester.pump();
    final handleDragged = controller.pages.single.imageBlocks.single.position;
    expect(handleDragged.dx, greaterThan(dragged.dx));
    expect(handleDragged.dy, greaterThan(dragged.dy));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
    controller.dispose();
    preferences.dispose();
    await database.close();
  });

  testWidgets('long press shows copy without OCR actions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final controller = _controller(database, 'photo.png');
    controller.setTool(DrawingTool.edit);
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

    await tester.longPressAt(const Offset(890, 260));
    await tester.pumpAndSettle();
    expect(find.text('Copy image'), findsOneWidget);
    expect(find.text('OCR text'), findsNothing);
    expect(find.text('Run OCR'), findsNothing);

    await tester.tapAt(const Offset(100, 100));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('inactive image must be selected before it can move', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final controller = _controller(database, 'photo.png');
    controller.setTool(DrawingTool.edit);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<EditorController>.value(
          value: controller,
          child: Scaffold(
            body: Consumer<EditorController>(
              builder: (context, editor, _) => SizedBox(
                width: 1200,
                height: 800,
                child: PageOverlay(controller: editor),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      const Offset(890, 260),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(30, 20));
    await gesture.up();
    await tester.pump();
    expect(controller.activeImageBlockId, isNull);
    expect(
      controller.pages.single.imageBlocks.single.position,
      const Offset(790, 200),
    );

    await tester.tapAt(const Offset(890, 260));
    await tester.pump();
    expect(controller.activeImageBlockId, 'page-image');

    for (final point in const [
      Offset(800, 210),
      Offset(890, 260),
      Offset(980, 310),
    ]) {
      await tester.tapAt(point);
      await tester.pump();
      expect(controller.activeImageBlockId, 'page-image');
    }

    controller.setTool(DrawingTool.lasso);
    expect(controller.activeImageBlockId, isNull);
    controller.setActiveImageBlock('page-image');
    expect(controller.activeImageBlockId, isNull);

    controller.setTool(DrawingTool.edit);
    await tester.pump();
    await tester.tapAt(const Offset(890, 260));
    await tester.pump();
    expect(controller.activeImageBlockId, 'page-image');

    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(controller.activeImageBlockId, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });
}
