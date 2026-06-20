import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/widgets/resizable_frame.dart';

void main() {
  testWidgets(
    'does not call setState while unmounting an active resize gesture',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: ResizableFrame(
              isSelected: true,
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(ResizableFrame)) + const Offset(1, 1),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));

      await tester.pumpWidget(const SizedBox.shrink());

      expect(tester.takeException(), isNull);
      await gesture.up();
    },
  );
}
