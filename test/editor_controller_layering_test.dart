import 'dart:typed_data';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/diagnostics/data_integrity_log.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('undo of last stroke is not treated as unexpected data loss', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final incidents = <DataIntegrityIncident>[];
    final repository = NotebookRepository(
      database,
      dataIntegrityIncidentHandler: (incident, _, _) async {
        incidents.add(incident);
      },
    );
    final source = await repository.createNotebook();
    final controller = EditorController(repository: repository, notebook: source);
    addTearDown(controller.dispose);
    controller.addInkStroke(
      const [InkPoint(dx: 5, dy: 10, pressure: 0.5)],
    );
    await controller.flushPendingSaves();

    controller.undo();
    await controller.flushPendingSaves();

    final saved = await repository.getNotebook(source.uid);
    expect(saved?.pages.single.inkStrokes, isEmpty);
    expect(incidents, isEmpty);
  });

  test('image deletion does not produce a false data-loss incident', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final incidents = <DataIntegrityIncident>[];
    final repository = NotebookRepository(
      database,
      dataIntegrityIncidentHandler: (incident, _, _) async {
        incidents.add(incident);
      },
    );
    final source = await repository.createNotebook();
    final image = ImageBlock(
      id: 'explicit-delete-image',
      path: '',
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      imageExt: 'png',
      imageMime: 'image/png',
      ocrText: '',
      position: Offset.zero,
      width: 100,
      height: 80,
    );
    final withImage = source.copyWith(
      updatedAt: DateTime.now().add(const Duration(seconds: 1)),
      pages: [source.pages.single.copyWith(imageBlocks: [image])],
    );
    expect(await repository.saveNotebook(withImage), isTrue);
    final saved = (await repository.getNotebook(source.uid))!;
    final controller = EditorController(repository: repository, notebook: saved);
    addTearDown(controller.dispose);

    controller.deleteImageBlock(image.id);
    await controller.flushPendingSaves();

    expect((await repository.getNotebook(source.uid))!
        .pages.single.imageBlocks, isEmpty);
    expect(incidents, isEmpty);
  });

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
