import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/operation_store.dart';
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

  test(
    'share object patch does not reset viewport or remount editor',
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
      expect(
        editor.applyConfirmedShareObjectPatch(
          pageId: page.id,
          objectId: stroke.id,
          stroke: stroke,
        ),
        isTrue,
      );
      expect(
        editor.currentPage.inkStrokes.map((item) => item.id),
        contains(stroke.id),
      );
      expect(editor.viewPan, const Offset(50, -20));
      expect(editor.viewScale, 1.5);
      expect(editor.currentPage.id, page.id);
      expect(editor.inkRevision.value, greaterThan(originalRevision));

      expect(
        editor.applyConfirmedShareObjectPatch(
          pageId: page.id,
          objectId: stroke.id,
          deleted: true,
        ),
        isTrue,
      );
      expect(editor.currentPage.inkStrokes, isEmpty);
      expect(editor.viewPan, const Offset(50, -20));
      expect(editor.viewScale, 1.5);
    },
  );

  test(
    'transient peer ink leaves pages, viewport and journal unchanged',
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
      final page = notebook.pages.single;
      final preview = InkStroke(
        id: 'unpersisted',
        color: const Color(0xff224466),
        width: 2,
        tool: DrawingTool.pen,
        points: [const InkPoint(dx: 4, dy: 8, pressure: 1)],
      );
      editor.setViewTransform(pan: const Offset(12, 18), scale: 1.25);
      editor.applyRemoteShareInkPreview(
        senderId: 'remote-peer',
        pageId: page.id,
        stroke: preview,
      );
      expect(editor.inkStrokesForDisplay(page).single.id, 'unpersisted');
      expect(editor.currentPage.inkStrokes, isEmpty);
      expect(await OperationStore(database).pending(), isEmpty);
      editor.applyRemoteShareInkPreview(
        senderId: 'remote-peer',
        pageId: page.id,
      );
      expect(editor.inkStrokesForDisplay(page), isEmpty);
      expect(editor.viewPan, const Offset(12, 18));
      expect(editor.viewScale, 1.25);
    },
  );

  test(
    'remote style patches preserve ink order until explicit reorder',
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
      final pageId = notebook.pages.single.id;
      InkStroke stroke(String id, int color) => InkStroke(
        id: id,
        color: Color(color),
        width: 2,
        tool: DrawingTool.pen,
        points: [const InkPoint(dx: 1, dy: 2, pressure: 1)],
      );
      final back = stroke('back', 0xFF000000);
      final front = stroke('front', 0xFFFFFFFF);
      expect(
        editor.applyConfirmedShareObjectPatch(
          pageId: pageId,
          objectId: back.id,
          stroke: back,
        ),
        isTrue,
      );
      expect(
        editor.applyConfirmedShareObjectPatch(
          pageId: pageId,
          objectId: front.id,
          stroke: front,
        ),
        isTrue,
      );
      expect(editor.currentPage.inkStrokes.map((item) => item.id), [
        'back',
        'front',
      ]);

      expect(
        editor.applyConfirmedShareObjectPatch(
          pageId: pageId,
          objectId: back.id,
          stroke: back.copyWith(color: const Color(0xFFAA1122)),
        ),
        isTrue,
      );
      expect(editor.currentPage.inkStrokes.map((item) => item.id), [
        'back',
        'front',
      ]);
      expect(editor.currentPage.inkStrokes.first.color.toARGB32(), 0xFFAA1122);

      expect(
        editor.applyConfirmedShareObjectPatch(
          pageId: pageId,
          objectId: front.id,
          stroke: front,
          sortIndex: 0,
        ),
        isTrue,
      );
      expect(editor.currentPage.inkStrokes.map((item) => item.id), [
        'front',
        'back',
      ]);
      expect(
        () => editor.applyConfirmedShareObjectPatch(
          pageId: pageId,
          objectId: front.id,
          stroke: front,
          sortIndex: -1,
        ),
        throwsArgumentError,
      );
      expect(editor.currentPage.inkStrokes.map((item) => item.id), [
        'front',
        'back',
      ]);
    },
  );

  test('share patch never overwrites an active local edit', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final editor = EditorController(repository: repository, notebook: notebook);
    addTearDown(editor.dispose);
    editor.addTextBlock(Offset.zero);
    final stroke = InkStroke(
      id: 'remote-stroke',
      color: const Color(0xFF112233),
      width: 2,
      tool: DrawingTool.pen,
      points: [const InkPoint(dx: 1, dy: 2, pressure: 1)],
    );
    expect(
      editor.applyConfirmedShareObjectPatch(
        pageId: notebook.pages.single.id,
        objectId: stroke.id,
        stroke: stroke,
      ),
      isFalse,
    );
    expect(editor.currentPage.inkStrokes, isEmpty);
  });
}
