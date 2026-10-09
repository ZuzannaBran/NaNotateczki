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
    expect(theme.colorScheme.onSurface, const Color(0xFFEEECE6));
    expect(AppTheme.light().brightness, Brightness.light);
  });

  test('grayscale ink is adapted only when dark mode is enabled', () {
    const black = Color(0xFF202020);
    const white = Color(0xFFFFFFFF);
    const blue = Color(0xFF2E5AAC);
    expect(AppColors.displayInkColor(black, darkMode: false), black);
    expect(
      AppColors.displayInkColor(black, darkMode: true),
      AppColors.darkText,
    );
    expect(
      AppColors.displayInkColor(white, darkMode: true),
      AppColors.darkBackground,
    );
    expect(AppColors.displayInkColor(blue, darkMode: true), blue);
    expect(
      AppColors.displayInkColor(
        const Color(0xFF1E2A40),
        darkMode: true,
      ),
      AppColors.darkText,
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
        theme: AppTheme.dark(),
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<EditorController>.value(value: controller),
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
          ],
          child: const EditorSettingsScreen(),
        ),
      ),
    );

    await tester.tap(find.text('Visual'));
    await tester.pumpAndSettle();
    final switchFinder = find.byKey(
      const ValueKey('visual-dark-mode-toggle'),
    );
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
    await tester.tap(switchFinder);
    await tester.pump();
    expect(preferences.darkMode, isTrue);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await database.close();
  });
}
