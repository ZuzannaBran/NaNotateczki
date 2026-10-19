import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/editor/state/input_mode.dart';

void main() {
  testWidgets('Flutter preserves touch and stylus input metadata', (
    tester,
  ) async {
    final received = <PointerEvent>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: received.add,
          onPointerMove: received.add,
          onPointerCancel: received.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 1,
        kind: PointerDeviceKind.touch,
        position: Offset(100, 100),
        radiusMajor: 55,
        radiusMinor: 34,
        buttons: kPrimaryButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerMoveEvent(
        pointer: 1,
        kind: PointerDeviceKind.touch,
        position: Offset(130, 115),
        delta: Offset(30, 15),
        buttons: kPrimaryButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerCancelEvent(
        pointer: 1,
        kind: PointerDeviceKind.touch,
        position: Offset(130, 115),
      ),
    );
    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 2,
        kind: PointerDeviceKind.stylus,
        position: Offset(160, 160),
        buttons: kPrimaryButton,
      ),
    );
    expect(received.map((event) => event.pointer), [1, 1, 1, 2]);
    expect(received.first.kind, PointerDeviceKind.touch);
    expect(received.first.radiusMajor, 55);
    expect(received[2], isA<PointerCancelEvent>());
    expect(received.last.kind, PointerDeviceKind.stylus);
    expect(PointerInputMode.off.allowsFingerDrawing, isTrue);
    expect(PointerInputMode.on.allowsFingerDrawing, isFalse);
  });
}
