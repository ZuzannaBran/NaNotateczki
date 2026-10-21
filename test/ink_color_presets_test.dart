import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/theme/app_colors.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/ink_color_presets.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  test('all three presets use the approved two-ink and marker colors', () {
    expect(InkColorPreset.blue.colors, [
      const Color(0xFF1A2130),
      const Color(0xFF3A4E6F),
      const Color(0xFF4B6493),
    ]);
    expect(InkColorPreset.pink.colors, [
      const Color(0xFF3A212B),
      const Color(0xFF6C3C4D),
      const Color(0xFF8E5066),
    ]);
    expect(InkColorPreset.green.colors, [
      const Color(0xFF1F3027),
      const Color(0xFF476E5E),
      const Color(0xFF5D927D),
    ]);
  });

  test('preset colors invert lightness only in dark mode', () {
    for (final preset in InkColorPreset.values) {
      for (final color in preset.colors) {
        expect(AppColors.displayInkColor(color, darkMode: false), color);
        final inverted = AppColors.displayInkColor(color, darkMode: true);
        final sourceHsl = HSLColor.fromColor(color);
        final invertedHsl = HSLColor.fromColor(inverted);
        expect(invertedHsl.lightness, closeTo(1 - sourceHsl.lightness, 0.005));
        expect(invertedHsl.hue, closeTo(sourceHsl.hue, 1.5));
      }
      expect(
        HSLColor.fromColor(preset.colors[0]).lightness,
        lessThan(0.2),
      );
      expect(
        HSLColor.fromColor(
          AppColors.displayInkColor(preset.colors[0], darkMode: true),
        ).lightness,
        greaterThan(0.8),
      );
    }
  });

  test('blue defaults and preset switches assign the third color to marker',
      () async {
    final database = NotesDatabase(NativeDatabase.memory());
    final now = DateTime(2026);
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: Notebook(
        uid: 'preset-test',
        title: 'Preset test',
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

    try {
      expect(controller.quickColors, InkColorPreset.blue.colors);
      expect(controller.penColor, InkColorPreset.blue.colors[0]);
      expect(controller.highlighterColor, InkColorPreset.blue.colors[2]);

      for (final preset in InkColorPreset.values) {
        controller.applyInkColorPreset(preset);
        expect(controller.quickColors, preset.colors);
        expect(controller.penColor, preset.colors[0]);
        expect(controller.highlighterColor, preset.colors[2]);
      }
    } finally {
      controller.dispose();
      await database.close();
    }
  });
}
