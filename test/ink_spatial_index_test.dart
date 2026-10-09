import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_spatial_index.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';

void main() {
  test('spatial index returns nearby strokes in source order', () {
    final strokes = <InkStroke>[
      _stroke('first', const Offset(20, 20), const Offset(40, 20)),
      _stroke('distant', const Offset(500, 500), const Offset(520, 500)),
      _stroke('second', const Offset(30, 30), const Offset(50, 30)),
    ];

    final result = inkSpatialIndexFor(
      strokes,
    ).queryPoint(const Offset(35, 25), 20);

    expect(result.map((stroke) => stroke.id), <String>['first', 'second']);
  });

  test('large strokes remain candidates without filling every grid cell', () {
    final largeStroke = _stroke(
      'large',
      const Offset(-10000, -10000),
      const Offset(10000, 10000),
    );
    final strokes = <InkStroke>[largeStroke];

    final result = inkSpatialIndexFor(strokes).queryPoint(Offset.zero, 4);

    expect(result, <InkStroke>[largeStroke]);
  });
}

InkStroke _stroke(String id, Offset start, Offset end) {
  return InkStroke(
    id: id,
    points: <InkPoint>[
      InkPoint.fromOffset(start, 1),
      InkPoint.fromOffset(end, 1),
    ],
    color: const Color(0xFF111111),
    width: 2,
    tool: DrawingTool.pen,
  );
}
