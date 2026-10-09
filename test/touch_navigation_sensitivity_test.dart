import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/input/touch_navigation_scroll_physics.dart';

void main() {
  test('sensitivity defaults to one and clamps invalid values', () async {
    final preferences = AppPreferencesController();
    expect(preferences.touchNavigationSensitivity, 1.0);

    preferences.previewTouchNavigationSensitivity(1.7);
    expect(preferences.touchNavigationSensitivity, 1.7);
    preferences.previewTouchNavigationSensitivity(4);
    expect(preferences.touchNavigationSensitivity, 2.0);
    preferences.previewTouchNavigationSensitivity(-2);
    expect(preferences.touchNavigationSensitivity, 0.5);
    preferences.previewTouchNavigationSensitivity(double.nan);
    expect(preferences.touchNavigationSensitivity, 0.5);
    preferences.dispose();
  });

  test('higher touch gain reduces navigation drag threshold', () {
    const slow = TouchNavigationScrollPhysics(sensitivity: 0.5);
    const fast = TouchNavigationScrollPhysics(sensitivity: 2.0);
    expect(
      fast.dragStartDistanceMotionThreshold!,
      lessThan(slow.dragStartDistanceMotionThreshold!),
    );
  });

  testWidgets('higher touch gain moves further for the same finger drag', (
    tester,
  ) async {
    Future<double> scrollBy(double sensitivity) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: ListView(
                controller: controller,
                physics: TouchNavigationScrollPhysics(
                  sensitivity: sensitivity,
                ),
                children: [
                  for (var i = 0; i < 60; i++)
                    const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        const Offset(150, 200),
        kind: PointerDeviceKind.touch,
      );
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -90));
      await tester.pump();
      final moved = controller.offset;
      await gesture.up();
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      return moved;
    }

    final slow = await scrollBy(0.5);
    final normal = await scrollBy(1.0);
    final fast = await scrollBy(2.0);

    expect(slow, greaterThan(0));
    expect(normal, greaterThan(slow));
    expect(fast, greaterThan(normal));
  });
}
