import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/editor/state/editor_actions.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_eraser_engine.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';

void main() {
  test('point eraser returns whole hit stroke', () {
    final hit = _stroke('hit', const [Offset(0, 0), Offset(100, 0)]);
    final miss = _stroke('miss', const [Offset(0, 40), Offset(100, 40)]);
    final ids = <String>{};

    InkEraserEngine.collectPointHits(
      strokes: [hit, miss],
      point: const Offset(50, 1),
      radius: 5,
      into: ids,
    );

    expect(ids, {'hit'});
  });

  test('brush eraser splits a sparse stroke instead of deleting it whole', () {
    final line = _stroke('line', const [Offset(0, 0), Offset(100, 0)]);
    var nextId = 0;

    final result = InkEraserEngine.eraseBrushParts(
      strokes: [line],
      path: const [Offset(50, -10), Offset(50, 10)],
      radius: 4,
      createId: () => 'part-${nextId++}',
    );

    expect(result.changed, isTrue);
    expect(result.strokes, hasLength(2));
    expect(
      result.strokes.every((stroke) => stroke.tool == DrawingTool.pen),
      isTrue,
    );
    expect(
      result.strokes
          .expand((stroke) => stroke.points)
          .any((point) => point.dx > 45 && point.dx < 55),
      isFalse,
    );
  });

  test('scratch erase uses the shared engine and returns fragments', () {
    final line = _stroke('scratch-line', const [
      Offset(0, 0),
      Offset(20, 0),
      Offset(40, 0),
      Offset(60, 0),
      Offset(80, 0),
      Offset(100, 0),
    ]);
    final gesture = const [
      InkPoint(dx: 50, dy: -10, pressure: 1),
      InkPoint(dx: 50, dy: 10, pressure: 1),
    ];
    var nextId = 0;

    final hits = InkEraserEngine.scratchInkHitCount(
      strokes: [line],
      gesture: gesture,
      radius: 2,
    );
    final result = InkEraserEngine.eraseScratchParts(
      strokes: [line],
      gesture: gesture,
      radius: 2,
      createId: () => 'scratch-part-${nextId++}',
    );

    expect(hits, greaterThan(0));
    expect(result.changed, isTrue);
    expect(result.strokes, hasLength(2));
    expect(result.strokes.any((stroke) => stroke.tool.isEraser), isFalse);
  });

  test('legacy brush flattening removes a covered single-point stroke', () {
    final dot = InkStroke(
      id: 'dot',
      points: const [InkPoint(dx: 10, dy: 10, pressure: 1)],
      color: const Color(0xFF000000),
      width: 2,
      tool: DrawingTool.pen,
    );
    final eraser = InkStroke(
      id: 'legacy-eraser',
      points: const [
        InkPoint(dx: 5, dy: 10, pressure: 1),
        InkPoint(dx: 15, dy: 10, pressure: 1),
      ],
      color: const Color(0xFFFFFFFF),
      width: 8,
      tool: DrawingTool.eraserBrush,
    );

    final result = InkEraserEngine.flattenLegacyErasers([dot, eraser]);

    expect(result.changed, isTrue);
    expect(result.strokes, isEmpty);
  });

  test('legacy fragment ids do not collide with existing stroke ids', () {
    final existing = _stroke('legacy-eraser_legacy_0', const [
      Offset(100, 0),
      Offset(120, 0),
    ]);
    final line = _stroke('line', const [
      Offset(0, 0),
      Offset(20, 0),
      Offset(40, 0),
      Offset(60, 0),
    ]);
    final eraser = InkStroke(
      id: 'legacy-eraser',
      points: const [
        InkPoint(dx: 30, dy: -10, pressure: 1),
        InkPoint(dx: 30, dy: 10, pressure: 1),
      ],
      color: const Color(0xFFFFFFFF),
      width: 4,
      tool: DrawingTool.eraserBrush,
    );

    final result = InkEraserEngine.flattenLegacyErasers([
      existing,
      line,
      eraser,
    ]);
    final ids = result.strokes.map((stroke) => stroke.id).toList();

    expect(ids.toSet(), hasLength(ids.length));
    expect(ids, contains(existing.id));
  });

  test('area eraser catches a stroke crossing the polygon', () {
    final crossing = _stroke('crossing', const [Offset(0, 0), Offset(100, 0)]);

    final ids = InkEraserEngine.areaHits(
      strokes: [crossing],
      polygon: const [
        Offset(40, -10),
        Offset(60, -10),
        Offset(60, 10),
        Offset(40, 10),
      ],
    );

    expect(ids, {'crossing'});
  });

  test('legacy eraser strokes are flattened out of saved ink', () {
    final ink = _stroke('ink', const [
      Offset(0, 0),
      Offset(20, 0),
      Offset(40, 0),
      Offset(60, 0),
      Offset(80, 0),
      Offset(100, 0),
    ]);
    final eraser = InkStroke(
      id: 'eraser',
      points: const [
        InkPoint(dx: 50, dy: -10, pressure: 1),
        InkPoint(dx: 50, dy: 10, pressure: 1),
      ],
      color: const Color(0xFFFFFFFF),
      width: 8,
      tool: DrawingTool.eraserBrush,
    );
    final laterInk = _stroke('later', const [Offset(0, 30), Offset(100, 30)]);

    final result = InkEraserEngine.flattenLegacyErasers([
      ink,
      eraser,
      laterInk,
    ]);

    expect(result.changed, isTrue);
    expect(result.strokes.any((stroke) => stroke.tool.isEraser), isFalse);
    expect(result.strokes.any((stroke) => stroke.id == 'later'), isTrue);
  });

  test('delete ink action restores original ordering on undo', () {
    final a = _stroke('a', const [Offset(0, 0), Offset(10, 0)]);
    final b = _stroke('b', const [Offset(0, 10), Offset(10, 10)]);
    final c = _stroke('c', const [Offset(0, 20), Offset(10, 20)]);
    final page = NotePage(
      id: 'page',
      title: 'Page',
      textBlocks: const [],
      imageBlocks: const [],
      inkStrokes: [a, b, c],
      isBookmarked: false,
    );
    final action = DeleteInkStrokesAction.fromStrokes(page.inkStrokes, {'b'});

    final erased = action.apply(page);
    final restored = action.revert(erased);

    expect(erased.inkStrokes.map((stroke) => stroke.id), ['a', 'c']);
    expect(restored.inkStrokes.map((stroke) => stroke.id), ['a', 'b', 'c']);
  });
}

InkStroke _stroke(String id, List<Offset> points) {
  return InkStroke(
    id: id,
    points: points.map((point) => InkPoint.fromOffset(point, 1)).toList(),
    color: const Color(0xFF000000),
    width: 2,
    tool: DrawingTool.pen,
  );
}
