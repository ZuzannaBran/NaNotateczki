import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ink and text tools send an active image behind content', () {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final image = ImageBlock(
      id: 'image',
      path: '',
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

    expect(controller.lastTextFontFamily, AppTheme.defaultFontFamily);

    controller.addTextBlock(const Offset(30, 40));

    expect(controller.tool, DrawingTool.edit);
    expect(controller.activeTextBlockId, isNotNull);
    expect(controller.activeImageBlockId, isNull);

    final textBlock = controller.pages.single.textBlocks.single;
    final delta = jsonDecode(textBlock.deltaJson!) as List<dynamic>;
    final firstOperation = delta.first as Map<String, dynamic>;
    final attributes = firstOperation['attributes'] as Map<String, dynamic>;
    expect(attributes['font'], AppTheme.defaultFontFamily);
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
