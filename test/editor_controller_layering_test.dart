import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ink and text tools send an active image behind content', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final image = ImageBlock(
      id: 'image',
      path: '',
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      imageExt: 'png',
      imageMime: 'image/png',
      ocrText: '',
      position: Offset.zero,
      width: 120,
      height: 80,
    );
    final controller = EditorController(
      repository: repository,
      notebook: _notebook(image),
    );
    addTearDown(controller.dispose);

    controller.setTool(DrawingTool.edit);
    controller.setActiveImageBlock(image.id);
    expect(controller.activeImageBlockId, image.id);

    controller.setTool(DrawingTool.pen);

    expect(controller.tool, DrawingTool.pen);
    expect(controller.activeImageBlockId, isNull);

    controller.setTool(DrawingTool.edit);
    controller.setActiveImageBlock(image.id);
    controller.setTool(DrawingTool.text);

    expect(controller.tool, DrawingTool.text);
    expect(controller.activeImageBlockId, isNull);

    controller.addTextBlock(const Offset(30, 40));

    expect(controller.tool, DrawingTool.edit);
    expect(controller.activeTextBlockId, isNotNull);
    expect(controller.activeImageBlockId, isNull);

    await controller.flushPendingSaves();
    final persisted = await repository.getNotebook(_notebook(image).uid);
    expect(persisted, isNotNull);
    expect(persisted!.pages.single.imageBlocks, hasLength(1));
    expect(persisted.pages.single.textBlocks, hasLength(1));
  });
}

Notebook _notebook(ImageBlock image) {
  final timestamp = DateTime.utc(2026, 10, 5);
  return Notebook(
    uid: 'image-layering-notebook',
    title: 'Image layering',
    kind: NotebookKind.notebook,
    folder: 'Notes',
    createdAt: timestamp,
    updatedAt: timestamp,
    pages: [
      NotePage(
        id: 'page',
        title: 'Page',
        textBlocks: const [],
        imageBlocks: [image],
        inkStrokes: const [],
        isBookmarked: false,
      ),
    ],
  );
}
