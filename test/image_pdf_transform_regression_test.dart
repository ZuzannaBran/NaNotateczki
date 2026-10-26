import 'dart:ui' show PointerDeviceKind;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
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
  }
}
