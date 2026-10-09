import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_eraser_engine.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';

InkStroke _line(String id, int row) => InkStroke(
  id: id,
  points: [
    for (var x = 0; x <= 100; x += 10)
      InkPoint(dx: x.toDouble(), dy: row * 20.0, pressure: 0.7),
  ],
  color: const Color(0xFF101010),
  width: 3,
  tool: DrawingTool.pen,
);

void main() {
  test('seeded multi-gesture erasure never resurrects removed stroke IDs', () {
    for (var seed = 0; seed < 12; seed++) {
      final rng = Random(seed);
      var strokes = [
        for (var row = 0; row < 12; row++) _line('initial-$row', row),
      ];
      var fragmentSequence = 0;
      final permanentlyRemoved = <String>{};

      for (var operation = 0; operation < 35; operation++) {
        final before = strokes.map((item) => item.id).toSet();
        final x = rng.nextInt(101).toDouble();
        final y = rng.nextInt(12) * 20.0;
        final result = InkEraserEngine.eraseBrushParts(
          strokes: strokes,
          path: [Offset(x, y - 9), Offset(x, y + 9)],
          radius: 4,
          createId: () => 'fragment-$seed-${fragmentSequence++}',
        );
        strokes = result.strokes;
        final ids = strokes.map((item) => item.id).toList();
        final current = ids.toSet();

        permanentlyRemoved.addAll(before.difference(current));
        expect(current, hasLength(ids.length), reason: 'seed=$seed');
        expect(
          current.intersection(permanentlyRemoved),
          isEmpty,
          reason: 'resurrected ID at seed=$seed operation=$operation',
        );
        expect(strokes.every((item) => !item.tool.isEraser), isTrue);
        expect(strokes.every((item) => item.points.isNotEmpty), isTrue);
      }
    }
  });

  test('invalid or empty eraser paths never mutate existing strokes', () {
    final original = [_line('keep', 0)];

    final empty = InkEraserEngine.eraseBrushParts(
      strokes: original,
      path: const [],
      radius: 5,
      createId: () => 'unused',
    );
    final zeroRadius = InkEraserEngine.eraseBrushParts(
      strokes: original,
      path: const [Offset(50, 0)],
      radius: 0,
      createId: () => 'unused',
    );

    expect(empty.changed, isFalse);
    expect(zeroRadius.changed, isFalse);
    expect(identical(empty.strokes, original), isTrue);
    expect(identical(zeroRadius.strokes, original), isTrue);
  });
}
