import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/backup/backup_eraser_flattening.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  test('flattens brush erasers into stroke fragments', () {
    final notebook = _notebook([
      _stroke('line', DrawingTool.pen, const [
        Offset(0, 0),
        Offset(5, 0),
        Offset(10, 0),
        Offset(15, 0),
        Offset(20, 0),
        Offset(25, 0),
        Offset(30, 0),
      ]),
      _stroke('eraser', DrawingTool.eraserBrush, const [
        Offset(10, -5),
        Offset(10, 5),
      ], width: 8),
    ]);

    final flattened = flattenErasersForBackup(notebook);
    final strokes = flattened.pages.single.inkStrokes;

    expect(strokes, hasLength(1));
    expect(strokes.single.tool, DrawingTool.pen);
    expect(strokes.single.id, isNot('line'));
    expect(strokes.single.points.map((point) => point.dx), [20, 25, 30]);
  });

  test('flattens area erasers and removes eraser strokes from backup', () {
    final notebook = _notebook([
      _stroke('left', DrawingTool.pen, const [Offset(0, 0), Offset(5, 0)]),
      _stroke('right', DrawingTool.pen, const [Offset(20, 0), Offset(25, 0)]),
      _stroke('area', DrawingTool.eraserArea, const [
        Offset(18, -4),
        Offset(27, -4),
        Offset(27, 4),
        Offset(18, 4),
      ]),
    ]);

    final flattened = flattenErasersForBackup(notebook);
    final strokes = flattened.pages.single.inkStrokes;

    expect(strokes, hasLength(1));
    expect(strokes.single.id, 'left');
    expect(strokes.single.tool, DrawingTool.pen);
  });
}

Notebook _notebook(List<InkStroke> strokes) {
  return Notebook(
    uid: 'notebook',
    title: 'Notebook',
    kind: NotebookKind.notebook,
    folder: 'Notes',
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024),
    pages: [
      NotePage(
        id: 'page',
        title: 'Page',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: strokes,
        isBookmarked: false,
        indexTabs: const [],
      ),
    ],
  );
}

InkStroke _stroke(
  String id,
  DrawingTool tool,
  List<Offset> offsets, {
  double width = 2,
}) {
  return InkStroke(
    id: id,
    points: offsets
        .map((offset) => InkPoint(dx: offset.dx, dy: offset.dy, pressure: 0.5))
        .toList(),
    color: const Color(0xFF000000),
    width: width,
    tool: tool,
  );
}
