import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:program/features/editor/presentation/interaction/text_hud_engine.dart';

void main() {
  test('translate previews from the initial geometry', () {
    final engine = TextHudEngine();
    const initial = TextHudGeometry(
      position: Offset(20, 30),
      width: 200,
      height: 60,
      fontSize: 20,
      rotation: 0,
    );

    engine.begin(TextHudOperation.translate, initial, const Offset(10, 10));
    final preview = engine.update(const Offset(35, 50));

    expect(preview.position, const Offset(45, 70));
    expect(engine.end()!.position, const Offset(45, 70));
    expect(engine.isActive, isFalse);
  });

  test('right width resize keeps the rotated left edge anchored', () {
    final engine = TextHudEngine();
    const initial = TextHudGeometry(
      position: Offset(100, 100),
      width: 200,
      height: 80,
      fontSize: 20,
      rotation: math.pi / 4,
    );
    final leftBefore = initial.pointAt(0, 0.5);
    final right = initial.pointAt(1, 0.5);

    engine.begin(TextHudOperation.resizeWidth, initial, right);
    final preview = engine.update(right + initial.axisX * 50);

    expect(preview.width, closeTo(250, 0.001));
    expect(
      (preview.pointAt(0, 0.5) - leftBefore).distance,
      lessThan(0.001),
    );
  });

  test('corner scale changes width, height and font size uniformly', () {
    final engine = TextHudEngine();
    const initial = TextHudGeometry(
      position: Offset(50, 40),
      width: 200,
      height: 60,
      fontSize: 20,
      rotation: 0,
    );
    final anchor = initial.pointAt(0, 0);
    final southEast = initial.pointAt(1, 1);

    engine.begin(TextHudOperation.scaleSouthEast, initial, southEast);
    final preview = engine.update(anchor + (southEast - anchor) * 1.5);

    expect(preview.width, closeTo(300, 0.001));
    expect(preview.height, closeTo(90, 0.001));
    expect(preview.fontSize, closeTo(30, 0.001));
    expect((preview.pointAt(0, 0) - anchor).distance, lessThan(0.001));
  });

  test('rotation snaps to 15 degrees while shift is held', () {
    final engine = TextHudEngine();
    const initial = TextHudGeometry(
      position: Offset.zero,
      width: 200,
      height: 80,
      fontSize: 20,
      rotation: 0,
    );
    final center = initial.center;
    final start = center + const Offset(0, -80);
    final target = center + const Offset(80, -20);

    engine.begin(TextHudOperation.rotate, initial, start);
    final preview = engine.update(target, shift: true);
    final degrees = preview.rotation * 180 / math.pi;

    expect((degrees / 15).round() * 15, closeTo(degrees, 0.001));
  });
}
