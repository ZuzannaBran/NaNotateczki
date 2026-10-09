import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/editor/presentation/interaction/object_transform_engine.dart';
import 'package:program/features/editor/presentation/widgets/object_transform_hud.dart';

void main() {
  testWidgets('top resize and move hit areas never overlap', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final frames = <Rect>[
      const Rect.fromLTWH(180, 220, 80, 40),
      const Rect.fromLTWH(160, 260, 300, 140),
      const Rect.fromLTWH(120, 260, 700, 400),
    ];

    for (final frame in frames) {
      final committed = <ObjectTransformKind>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ObjectTransformHud<Rect>(
                  key: ValueKey('hud-${frame.width}'),
                  data: frame,
                  rect: frame,
                  rotation: 0,
                  draggable: false,
                  enabledHandles: const {HandlePosition.top},
                  onPreview: (_, _) {},
                  onCommit: (_, preview) => committed.add(preview.kind),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final move = find.byKey(const ValueKey('object-transform-move-hit-zone'));
      final resize = find.byKey(
        const ValueKey('object-transform-top-hit-zone'),
      );
      expect(move, findsOneWidget);
      expect(resize, findsOneWidget);
      final moveRect = tester.getRect(move);
      final resizeRect = tester.getRect(resize);
      expect(moveRect.bottom, closeTo(resizeRect.top, 0.01));
      expect(moveRect.overlaps(resizeRect), isFalse);

      final movePointer = await tester.startGesture(
        tester.getCenter(move),
        kind: PointerDeviceKind.stylus,
      );
      await movePointer.moveBy(const Offset(12, -4));
      await tester.pump();
      await movePointer.up();
      await tester.pump();
      expect(committed, [ObjectTransformKind.move]);

      final resizePointer = await tester.startGesture(
        tester.getCenter(resize),
        kind: PointerDeviceKind.touch,
      );
      await resizePointer.moveBy(const Offset(0, 6));
      await tester.pump();
      await resizePointer.up();
      await tester.pump();
      expect(committed, [ObjectTransformKind.move, ObjectTransformKind.resize]);
    }
  });

  testWidgets('canceling a pointer does not commit the transform', (
    tester,
  ) async {
    var commits = 0;
    var cancels = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ObjectTransformHud<int>(
                data: 1,
                rect: const Rect.fromLTWH(100, 150, 200, 100),
                rotation: 0,
                draggable: false,
                enabledHandles: const {HandlePosition.top},
                onPreview: (_, _) {},
                onCommit: (_, _) => commits++,
                onCancel: (_) => cancels++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('object-transform-move-hit-zone')),
      ),
    );
    await gesture.moveBy(const Offset(40, 20));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();

    expect(commits, 0);
    expect(cancels, 1);
  });
}
