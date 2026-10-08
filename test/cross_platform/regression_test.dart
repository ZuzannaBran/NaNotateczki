import 'dart:ui';

import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/editor/presentation/interaction/object_transform_engine.dart';
import 'package:program/features/editor/state/page_background.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_eraser_engine.dart';
import 'package:program/features/notebook/domain/ink_spatial_index.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';

InkStroke stroke(String id, double y) => InkStroke(
  id: id,
  points: [
    for (var x = 0; x <= 100; x += 5)
      InkPoint(dx: x.toDouble(), dy: y, pressure: 0.7),
  ],
  color: const Color(0xFF131313),
  width: 3,
  tool: DrawingTool.pen,
);

void main() {
  group('destructive ink erasing regressions', () {
    test('adjacent second erase never resurrects the previous ink', () {
      final first = stroke('first', 0);
      final second = stroke('second', 30);
      var nextId = 0;

      final firstPass = InkEraserEngine.eraseBrushParts(
        strokes: [first, second],
        path: const [Offset(50, -8), Offset(50, 8)],
        radius: 4,
        createId: () => 'fragment-${nextId++}',
      );
      expect(firstPass.changed, isTrue);
      expect(firstPass.strokes.any((item) => item.id == 'first'), isFalse);
      expect(firstPass.strokes.any((item) => item.id == 'second'), isTrue);

      final secondPass = InkEraserEngine.eraseBrushParts(
        strokes: firstPass.strokes,
        path: const [Offset(50, 20), Offset(50, 40)],
        radius: 4,
        createId: () => 'fragment-${nextId++}',
      );
      expect(secondPass.changed, isTrue);
      expect(secondPass.strokes.any((item) => item.id == 'first'), isFalse);
      expect(secondPass.strokes.any((item) => item.id == 'second'), isFalse);
      expect(
        secondPass.strokes
            .where((item) => item.points.first.dy == 0)
            .expand((item) => item.points)
            .any((point) => point.dx > 46 && point.dx < 54),
        isFalse,
      );

      final repeated = InkEraserEngine.eraseBrushParts(
        strokes: secondPass.strokes,
        path: const [Offset(50, -8), Offset(50, 40)],
        radius: 4,
        createId: () => 'fragment-${nextId++}',
      );
      expect(repeated.changed, isFalse);
      expect(
        repeated.strokes.map((item) => item.id).toList(),
        secondPass.strokes.map((item) => item.id).toList(),
      );
      expect(
        repeated.strokes.map((item) => item.id).toSet(),
        hasLength(repeated.strokes.length),
      );
    });

    test('legacy eraser normalization is one-way and idempotent', () {
      final source = NotePage(
        id: 'page',
        title: 'Page',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: [
          stroke('older', 0),
          InkStroke(
            id: 'mask',
            points: const [
              InkPoint(dx: 50, dy: -12, pressure: 1),
              InkPoint(dx: 50, dy: 12, pressure: 1),
            ],
            color: const Color(0xFFFFFFFF),
            width: 8,
            tool: DrawingTool.eraserBrush,
          ),
          stroke('newer', 30),
        ],
        isBookmarked: false,
      );
      final once = InkEraserEngine.normalizePage(source);
      final twice = InkEraserEngine.normalizePage(once);

      expect(identical(once, source), isFalse);
      expect(identical(twice, once), isTrue);
      expect(once.inkStrokes.any((item) => item.tool.isEraser), isFalse);
      expect(once.inkStrokes.any((item) => item.id == 'newer'), isTrue);
      expect(
        once.inkStrokes.map((item) => item.id).toSet(),
        hasLength(once.inkStrokes.length),
      );
    });

    test('spatial index for modified stroke list has no deleted ink', () {
      final original = [stroke('first', 0), stroke('second', 30)];
      final before = inkSpatialIndexFor(original);
      expect(
        before.queryPoint(const Offset(50, 0), 4).map((item) => item.id),
        contains('first'),
      );

      final after = original.where((item) => item.id != 'first').toList();
      final index = inkSpatialIndexFor(after);
      expect(
        index.queryPoint(const Offset(50, 0), 4).map((item) => item.id),
        isNot(contains('first')),
      );
      expect(
        index.queryPoint(const Offset(50, 30), 4).single.id,
        'second',
      );
    });
  });

  group('coordinate transformations', () {
    test('move uses world coordinates and can be reversed', () {
      final engine = ObjectTransformEngine();
      const original = Rect.fromLTWH(40, 70, 200, 100);
      engine.beginMove(
        rect: original,
        rotation: 0,
        pointer: const Offset(60, 90),
      );
      expect(
        engine.update(const Offset(110, 130)).rect.topLeft,
        const Offset(90, 110),
      );
      expect(engine.update(const Offset(60, 90)).rect, original);
      expect(engine.end()?.rect, original);
      expect(engine.isActive, isFalse);
    });

    test('aborted resize cannot retain a stale preview', () {
      final engine = ObjectTransformEngine();
      const original = Rect.fromLTWH(10, 20, 180, 90);
      engine.beginResize(
        rect: original,
        rotation: 0,
        pointer: original.bottomRight,
        handle: HandlePosition.bottomRight,
        resizeMode: ResizeMode.scale,
      );
      expect(
        engine.update(const Offset(280, 180)).rect.width,
        greaterThan(original.width),
      );
      engine.cancel();
      expect(engine.isActive, isFalse);
      expect(engine.end(), isNull);
      engine.beginMove(
        rect: original,
        rotation: 0,
        pointer: original.center,
      );
      expect(engine.update(original.center).rect, original);
    });
  });

  group('saved preferences', () {
    test('background serializes and survives invalid historical values', () {
      const settings = PageBackgroundSettings(
        style: PageBackgroundStyle.grid,
        spacing: 40,
      );
      final restored = PageBackgroundSettings.fromJson(settings.toJson());
      expect(restored.style, settings.style);
      expect(restored.spacing, settings.spacing);

      final invalid = PageBackgroundSettings.fromJson({
        'style': -5,
        'spacing': 100000,
      });
      expect(invalid.style, PageBackgroundStyle.blank);
      expect(invalid.spacing, PageBackgroundSettings.maxSpacing);
      expect(
        PageBackgroundSettings.fromJson({'spacing': -100}).spacing,
        PageBackgroundSettings.minSpacing,
      );
    });
  });
}
