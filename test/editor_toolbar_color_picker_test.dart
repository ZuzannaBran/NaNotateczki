import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/theme/app_colors.dart';
import 'package:program/features/editor/presentation/widgets/editor_toolbar.dart';

void main() {
  const initial = Color(0xFF203E85);
  const recent = Color(0xFF7AD5B2);

  Future<void> openPicker(
    WidgetTester tester, {
    required bool darkMode,
    required ValueChanged<Color?> onSelected,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkMode ? ThemeData.dark() : ThemeData.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  final color = await EditorToolbar.pickColor(
                    context,
                    initial,
                    const <Color>[recent],
                  );
                  onSelected(color);
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
  }

  Color previewColor(WidgetTester tester) {
    final box = tester.widget<Container>(
      find.byKey(const ValueKey('color-picker-preview')),
    );
    return (box.decoration! as BoxDecoration).color!;
  }

  String hex(Color color) {
    final digits = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${digits.substring(2).toUpperCase()}';
  }

  void expectDisplayNear(Color actual, Color expected) {
    expect((actual.r - expected.r).abs(), lessThan(2 / 255));
    expect((actual.g - expected.g).abs(), lessThan(2 / 255));
    expect((actual.b - expected.b).abs(), lessThan(2 / 255));
  }

  Finder recentSwatch() => find.byKey(
    ValueKey('color-picker-recent-${recent.toARGB32()}'),
  );

  testWidgets('dark picker inverts recent swatch, HEX and RGB channels', (
    tester,
  ) async {
    Color? selected;
    await openPicker(
      tester,
      darkMode: true,
      onSelected: (color) => selected = color,
    );
    final visibleInitial = AppColors.displayInkColor(initial, darkMode: true);
    final visibleRecent = AppColors.displayInkColor(recent, darkMode: true);
    expect(previewColor(tester), visibleInitial);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      hex(visibleInitial),
    );
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders, hasLength(4));
    expect(sliders[0].value, closeTo(visibleInitial.r * 255, 1));
    expect(sliders[1].value, closeTo(visibleInitial.g * 255, 1));
    expect(sliders[2].value, closeTo(visibleInitial.b * 255, 1));
    final swatch = tester.widget<GestureDetector>(recentSwatch());
    expect(
      ((swatch.child! as Container).decoration! as BoxDecoration).color,
      visibleRecent,
    );
    await tester.tap(recentSwatch());
    await tester.pumpAndSettle();
    expect(selected, recent);
  });

  testWidgets('dark picker saves edited HEX and RGB as visible preview', (
    tester,
  ) async {
    Color? selected;
    await openPicker(
      tester,
      darkMode: true,
      onSelected: (color) => selected = color,
    );
    const chosenDisplay = Color(0xFF3268B4);
    await tester.enterText(find.byType(TextField), hex(chosenDisplay));
    await tester.pump();
    expect(previewColor(tester), chosenDisplay);
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders[0].value, closeTo(chosenDisplay.r * 255, 1));
    expect(sliders[1].value, closeTo(chosenDisplay.g * 255, 1));
    expect(sliders[2].value, closeTo(chosenDisplay.b * 255, 1));
    final beforeRed = sliders[0].value;
    await tester.drag(find.byType(Slider).first, const Offset(50, 0));
    await tester.pump();
    expect(
      tester.widget<Slider>(find.byType(Slider).first).value,
      greaterThan(beforeRed),
    );
    final visiblePreview = previewColor(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(selected, isNotNull);
    expectDisplayNear(
      AppColors.displayInkColor(selected!, darkMode: true),
      visiblePreview,
    );
  });

  testWidgets('untouched picker never mutates stored dark or light colors', (
    tester,
  ) async {
    for (final darkMode in [false, true]) {
      Color? selected;
      await openPicker(
        tester,
        darkMode: darkMode,
        onSelected: (color) => selected = color,
      );
      expect(
        previewColor(tester),
        AppColors.displayInkColor(initial, darkMode: darkMode),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      expect(selected, initial);
    }
  });

  testWidgets('light picker keeps raw recent swatch, HEX and selection', (
    tester,
  ) async {
    Color? selected;
    await openPicker(
      tester,
      darkMode: false,
      onSelected: (color) => selected = color,
    );
    expect(previewColor(tester), initial);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      hex(initial),
    );
    final swatch = tester.widget<GestureDetector>(recentSwatch());
    expect(
      ((swatch.child! as Container).decoration! as BoxDecoration).color,
      recent,
    );
    await tester.tap(recentSwatch());
    await tester.pumpAndSettle();
    expect(selected, recent);
  });
}
