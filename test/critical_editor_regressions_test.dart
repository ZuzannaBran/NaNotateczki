import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

Notebook _notebook() {
  final now = DateTime.utc(2026, 10, 8);
  return Notebook(
    uid: 'editor-regression',
    title: 'Regression',
    kind: NotebookKind.board,
    folder: 'Tests',
    createdAt: now,
    updatedAt: now,
    pages: [
      NotePage(
        id: 'board-page',
        title: 'Board',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: const [],
        isBookmarked: false,
      ),
    ],
  );
}

List<InkPoint> _line(double y) => [
  for (var x = 0; x <= 100; x += 10)
    InkPoint(dx: x.toDouble(), dy: y, pressure: 0.8),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('erase, lasso move, save and reopen never revive erased ink', () async {
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = NotebookRepository(db);
    final notebook = _notebook();
    expect(await repository.saveNotebook(notebook), isTrue);

    final editor = EditorController(
      repository: repository,
      notebook: notebook,
    );
    addTearDown(editor.dispose);

    final erasedId = editor.addInkStroke(
      _line(10),
      toolOverride: DrawingTool.pen,
    );
    final keptId = editor.addInkStroke(
      _line(65),
      toolOverride: DrawingTool.pen,
    );
    expect(erasedId, isNotNull);
    expect(keptId, isNotNull);
    expect(editor.currentPage.inkStrokes, hasLength(2));

    editor.eraseInkStrokesById({erasedId!});
    expect(editor.currentPage.inkStrokes.map((s) => s.id), [keptId]);

    editor.selectWithLasso(const [
      Offset(-5, 50),
      Offset(110, 50),
      Offset(110, 80),
      Offset(-5, 80),
    ], 0);
    expect(editor.lassoSelection?.strokeIds, [keptId]);
    editor.updateLassoMove(const Offset(35, 20));
    editor.commitLassoMove();

    expect(editor.currentPage.inkStrokes, hasLength(1));
    final moved = editor.currentPage.inkStrokes.single;
    expect(moved.id, keptId);
    expect(moved.points.first.dx, 35);
    expect(moved.points.first.dy, 85);

    await editor.flushPendingSaves();
    await repository.waitForPendingSaves();
    final persisted = await repository.getNotebook(notebook.uid);
    expect(persisted, isNotNull);
    expect(persisted!.pages.single.inkStrokes, hasLength(1));
    expect(persisted.pages.single.inkStrokes.single.id, keptId);
    expect(persisted.pages.single.inkStrokes.single.points.first.dx, 35);

    final reopened = EditorController(
      repository: repository,
      notebook: persisted,
    );
    addTearDown(reopened.dispose);
    expect(reopened.pages.single.inkStrokes, hasLength(1));
    expect(reopened.pages.single.inkStrokes.single.id, keptId);
  });

  test('multi-erase undo/redo restores only explicitly requested history',
      () async {
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = NotebookRepository(db);
    final notebook = _notebook();
    expect(await repository.saveNotebook(notebook), isTrue);
    final editor = EditorController(
      repository: repository,
      notebook: notebook,
    );
    addTearDown(editor.dispose);

    final first = editor.addInkStroke(_line(5), toolOverride: DrawingTool.pen);
    final second = editor.addInkStroke(_line(35), toolOverride: DrawingTool.pen);
    editor.eraseInkStrokesById({first!});
    editor.eraseInkStrokesById({second!});
    expect(editor.currentPage.inkStrokes, isEmpty);

    editor.undo();
    expect(editor.currentPage.inkStrokes.map((s) => s.id), [second]);
    editor.undo();
    expect(editor.currentPage.inkStrokes.map((s) => s.id), [first, second]);
    editor.redo();
    expect(editor.currentPage.inkStrokes.map((s) => s.id), [second]);
    editor.redo();
    expect(editor.currentPage.inkStrokes, isEmpty);

    await editor.flushPendingSaves();
    await repository.waitForPendingSaves();
    final saved = await repository.getNotebook(notebook.uid);
    expect(saved?.pages.single.inkStrokes, isEmpty);
  });

  test('object transform blocks viewport without shifting world coordinates',
      () async {
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final editor = EditorController(
      repository: NotebookRepository(db),
      notebook: _notebook(),
    );
    addTearDown(editor.dispose);

    editor.setViewTransform(
      pan: const Offset(70, -30),
      scale: 1.8,
    );
    const world = Offset(30, 50);
    final screen = editor.worldToViewport(world);
    expect(editor.viewportToWorld(screen).dx, closeTo(world.dx, 0.00001));
    expect(editor.viewportToWorld(screen).dy, closeTo(world.dy, 0.00001));

    editor.beginObjectTransform();
    editor.panBy(const Offset(500, 500));
    editor.zoomBy(2, focalPoint: screen);
    expect(editor.worldToViewport(world), screen);

    editor.endObjectTransform();
    editor.panBy(const Offset(5, 0));
    expect(editor.worldToViewport(world), screen + const Offset(5, 0));
  });
}
