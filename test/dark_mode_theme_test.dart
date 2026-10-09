import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/editor_settings_screen.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  test('dark palette matches the Visual reference', () {
    final theme = AppTheme.dark();
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, const Color(0xFF2D2E2B));
    expect(theme.colorScheme.surfaceContainerLow, const Color(0xFF3A3B39));
    expect(theme.colorScheme.primaryContainer, const Color(0xFF4A4B48));
    expect(theme.cardColor, const Color(0xFF5A5B57));
    expect(AppColors.darkCanvas, const Color(0xFF50514D));
    expect(theme.colorScheme.onSurface, const Color(0xFFEEECE6));
    expect(AppTheme.light().brightness, Brightness.light);
  });

  test('all ink colors invert lightness without changing hue', () {
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    const lightBlue = Color(0xFFBBDCFB);
    const darkBlue = Color(0xFF203E85);
    const lightPink = Color(0xFFFFC1CC);
    const translucent = Color(0x8078A8E0);

    expect(
      AppColors.displayInkColor(black, darkMode: true),
      Colors.white,
    );
    expect(
      AppColors.displayInkColor(white, darkMode: true),
      Colors.black,
    );
    for (final original in [
      lightBlue,
      darkBlue,
      lightPink,
      translucent,
      const Color(0xFF1E2A40),
      const Color(0xFF202020),
      const Color(0xFF2E5AAC),
    ]) {
      expect(
        AppColors.displayInkColor(original, darkMode: false),
        original,
      );
      final transformed = AppColors.displayInkColor(
        original,
        darkMode: true,
      );
      final sourceHsl = HSLColor.fromColor(original);
      final targetHsl = HSLColor.fromColor(transformed);
      expect(
        targetHsl.lightness,
        closeTo(1 - sourceHsl.lightness, 0.005),
      );
      if (sourceHsl.saturation > 0.01) {
        expect(targetHsl.hue, closeTo(sourceHsl.hue, 1.5));
      }
      expect(transformed.a, closeTo(original.a, 0.001));
    }
    expect(
      HSLColor.fromColor(
        AppColors.displayInkColor(lightBlue, darkMode: true),
      ).lightness,
      lessThan(HSLColor.fromColor(lightBlue).lightness),
    );
    expect(
      HSLColor.fromColor(
        AppColors.displayInkColor(darkBlue, darkMode: true),
      ).lightness,
      greaterThan(HSLColor.fromColor(darkBlue).lightness),
    );
  });

  test('dark mode is initially off for existing preferences', () {
    final preferences = AppPreferencesController();
    expect(preferences.darkMode, isFalse);
    preferences.dispose();
  });

  testWidgets('Visual tab offers a working dark mode switch', (tester) async {
    final database = NotesDatabase(NativeDatabase.memory());
    final now = DateTime(2026);
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: Notebook(
        uid: 'visual-mode-test',
        title: 'Visual mode',
        kind: NotebookKind.notebook,
        folder: 'Tests',
        createdAt: now,
        updatedAt: now,
        pages: [
          NotePage(
            id: 'page',
            title: 'Page',
            textBlocks: const [],
            imageBlocks: const [],
            inkStrokes: const [],
            isBookmarked: false,
          ),
        ],
      ),
    );
    final preferences = AppPreferencesController();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<EditorController>.value(value: controller),
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
          ],
          child: Consumer<AppPreferencesController>(
            builder: (context, prefs, _) => Theme(
              data: prefs.darkMode ? AppTheme.dark() : AppTheme.light(),
              child: const EditorSettingsScreen(),
            ),
          ),
        ),
      ),
    );

    final navigationSlider = find.byKey(
      const ValueKey('touch-navigation-sensitivity'),
    );
    expect(navigationSlider, findsOneWidget);
    final initialSlider = tester.widget<Slider>(navigationSlider);
    expect(initialSlider.value, 1.0);
    expect(initialSlider.min, 0.5);
    expect(initialSlider.max, 2.0);
    initialSlider.onChanged!(1.6);
    await tester.pump();
    expect(preferences.touchNavigationSensitivity, 1.6);
    expect(tester.widget<Slider>(navigationSlider).value, 1.6);
    expect(find.text('1.6×'), findsOneWidget);

    await tester.tap(find.text('Visual'));
    await tester.pumpAndSettle();
    final switchFinder = find.byKey(
      const ValueKey('visual-dark-mode-toggle'),
    );
    final lightControl = tester.widget<SegmentedButton<bool>>(
      switchFinder,
    );
    expect(lightControl.selected, {false});
    expect(
      lightControl.style!.backgroundColor!.resolve({
        WidgetState.selected,
      }),
      AppColors.divider,
    );
    expect(
      lightControl.style!.backgroundColor!.resolve({}),
      AppColors.toolbar,
    );
    expect(
      lightControl.style!.foregroundColor!.resolve({
        WidgetState.selected,
      }),
      AppColors.inkBlack,
    );
    expect(
      lightControl.style!.foregroundColor!.resolve({}),
      AppColors.inkBlack,
    );
    expect(
      lightControl.style!.side!.resolve({WidgetState.selected})!.width,
      greaterThan(lightControl.style!.side!.resolve({})!.width),
    );

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(preferences.darkMode, isTrue);
    final darkControl = tester.widget<SegmentedButton<bool>>(
      switchFinder,
    );
    expect(darkControl.selected, {true});
    expect(
      darkControl.style!.backgroundColor!.resolve({
        WidgetState.selected,
      }),
      AppColors.darkActive,
    );
    expect(
      darkControl.style!.backgroundColor!.resolve({}),
      AppColors.darkToolbar,
    );
    expect(
      darkControl.style!.foregroundColor!.resolve({
        WidgetState.selected,
      }),
      AppColors.darkText,
    );
    expect(
      darkControl.style!.foregroundColor!.resolve({}),
      AppColors.darkText,
    );
    expect(
      darkControl.style!.side!.resolve({WidgetState.selected})!.width,
      greaterThan(darkControl.style!.side!.resolve({})!.width),
    );

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(preferences.darkMode, isFalse);
    expect(
      tester.widget<SegmentedButton<bool>>(switchFinder).selected,
      {false},
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await database.close();
  });
}
