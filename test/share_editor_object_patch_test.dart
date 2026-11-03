import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    textStorageReadOverride = (_) async => null;
    textStorageWriteOverride = (_, _) async {};
  });

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('share object patch does not reset viewport or remount editor',
      () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final editor = EditorController(
      repository: repository,
      notebook: notebook,
    );
    addTearDown(editor.dispose);
    editor.setViewTransform(pan: const Offset(50, -20), scale: 1.5);
    final page = notebook.pages.single;
    final stroke = InkStroke(
      id: 'shared-stroke',
      color: const Color(0xFF112233),
      width: 3,
      tool: DrawingTool.pen,
      points: [const InkPoint(dx: 2, dy: 4, pressure: 0.8)],
    );
    final originalRevision = editor.inkRevision.value;
    expect(editor.applyConfirmedShareObjectPatch(
      pageId: page.id,
      objectId: stroke.id,
      stroke: stroke,
    ), isTrue);
    expect(editor.currentPage.inkStrokes.map((item) => item.id),
        contains(stroke.id));
    expect(editor.viewPan, const Offset(50, -20));
    expect(editor.viewScale, 1.5);
    expect(editor.currentPage.id, page.id);
    expect(editor.inkRevision.value, greaterThan(originalRevision));

    expect(editor.applyConfirmedShareObjectPatch(
      pageId: page.id,
      objectId: stroke.id,
      deleted: true,
    ), isTrue);
    expect(editor.currentPage.inkStrokes, isEmpty);
    expect(editor.viewPan, const Offset(50, -20));
    expect(editor.viewScale, 1.5);
  });

  test('share patch never overwrites an active local edit', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final editor = EditorController(
      repository: repository,
      notebook: notebook,
    );
    addTearDown(editor.dispose);
    editor.addTextBlock(Offset.zero);
    final stroke = InkStroke(
      id: 'remote-stroke',
      color: const Color(0xFF112233),
      width: 2,
      tool: DrawingTool.pen,
      points: [const InkPoint(dx: 1, dy: 2, pressure: 1)],
    );
    expect(editor.applyConfirmedShareObjectPatch(
      pageId: notebook.pages.single.id,
      objectId: stroke.id,
      stroke: stroke,
    ), isFalse);
    expect(editor.currentPage.inkStrokes, isEmpty);
  });
}
