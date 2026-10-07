import 'dart:math' as math;

import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/features/editor/presentation/interaction/object_transform_engine.dart';

void main() {
  test('move works in logical coordinates', () {
    final engine = ObjectTransformEngine();
    const rect = Rect.fromLTWH(20, 30, 200, 80);

    engine.beginMove(
      rect: rect,
      rotation: 0,
      pointer: const Offset(40, 50),
    );
    final preview = engine.update(const Offset(70, 95));

    expect(preview.rect.topLeft, const Offset(50, 75));
    expect(preview.rect.size, rect.size);
  });

  test('corner scale preserves aspect ratio', () {
    final engine = ObjectTransformEngine();
    const rect = Rect.fromLTWH(10, 20, 200, 100);

    engine.beginResize(
      rect: rect,
      rotation: 0,
      pointer: rect.bottomRight,
      handle: HandlePosition.bottomRight,
      resizeMode: ResizeMode.scale,
    );
    final preview = engine.update(const Offset(310, 170));

    expect(preview.rect.width / preview.rect.height, closeTo(2, 0.001));
    expect(preview.rect.topLeft, rect.topLeft);
  });

  test('side resize changes only the driven axis', () {
    final engine = ObjectTransformEngine();
    const rect = Rect.fromLTWH(10, 20, 200, 100);

    engine.beginResize(
      rect: rect,
      rotation: 0,
      pointer: rect.centerRight,
      handle: HandlePosition.right,
      resizeMode: ResizeMode.freeform,
    );
    final preview = engine.update(const Offset(260, 70));

    expect(preview.rect.width, closeTo(250, 0.001));
    expect(preview.rect.height, closeTo(100, 0.001));
    expect(preview.rect.left, closeTo(10, 0.001));
  });

  test('rotation can snap to fifteen degree increments', () {
    final engine = ObjectTransformEngine();
    const rect = Rect.fromLTWH(0, 0, 200, 80);
    final start = rect.topCenter;
    const target = Offset(190, -30);

    engine.beginRotate(
      rect: rect,
      rotation: 0,
      pointer: start,
    );
    final preview = engine.update(target, snapRotation: true);
    final degrees = preview.rotation * 180 / math.pi;

    expect(degrees / 15, closeTo((degrees / 15).roundToDouble(), 0.001));
  });
}
