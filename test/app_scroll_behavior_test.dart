import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/app/notes_app.dart';
import 'package:program/core/input/app_scroll_behavior.dart';

void main() {
  testWidgets('app installs scrollbar-free behavior globally', (
    tester,
  ) async {
    await tester.pumpWidget(const NotesApp());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.scrollBehavior, isA<AppScrollBehavior>());
  });

  testWidgets('desktop hides scrollbars but keeps touch and wheel scrolling', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: SizedBox(
            height: 180,
            child: ListView.builder(
              controller: controller,
              itemExtent: 48,
              itemCount: 40,
              itemBuilder: (context, index) => Text('Item $index'),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Scrollbar), findsNothing);
    expect(find.byType(RawScrollbar), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));

    final offsetAfterTouch = controller.offset;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ListView)),
        scrollDelta: const Offset(0, 160),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(offsetAfterTouch));
    expect(find.byType(Scrollbar), findsNothing);
    expect(find.byType(RawScrollbar), findsNothing);
  });
}
