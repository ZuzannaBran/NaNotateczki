import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/app/app_scope.dart';

void main() {
  testWidgets('interface scale adjusts viewport and pointer hit testing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    Size? logicalSize;
    var taps = 0;

    Widget app(double scale) {
      return MaterialApp(
        builder: (context, child) => AppUiScale(
          scale: scale,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Builder(
          builder: (context) {
            logicalSize = MediaQuery.sizeOf(context);
            return Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 120,
                  height: 48,
                  child: ElevatedButton(
                    key: const ValueKey('scaled-button'),
                    onPressed: () => taps++,
                    child: const Text('Tap'),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    await tester.pumpWidget(app(1.5));
    expect(logicalSize!.width, closeTo(600, 0.01));
    expect(logicalSize!.height, closeTo(400, 0.01));
    expect(
      tester.getRect(find.byKey(const ValueKey('scaled-button'))).width,
      closeTo(180, 0.01),
    );
    await tester.tapAt(const Offset(170, 35));
    await tester.pump();
    expect(taps, 1);

    await tester.pumpWidget(app(0.75));
    expect(logicalSize!.width, closeTo(1200, 0.01));
    expect(logicalSize!.height, closeTo(800, 0.01));
    expect(
      tester.getRect(find.byKey(const ValueKey('scaled-button'))).width,
      closeTo(90, 0.01),
    );
    await tester.tapAt(const Offset(80, 20));
    await tester.pump();
    expect(taps, 2);

    await tester.pumpWidget(app(1));
    expect(logicalSize, const Size(900, 600));
  });
}
