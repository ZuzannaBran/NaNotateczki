import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/theme/app_colors.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/ink_color_presets.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  test('presets retain their hues with three progressively lighter tones', () {
    expect(InkColorPreset.blue.colors, [
      const Color(0xFF1A2130),
      const Color(0xFF7798C0),
      const Color(0xFFACBED8),
    ]);
    expect(InkColorPreset.pink.colors, [
      const Color(0xFF3A212B),
      const Color(0xFFA9788A),
      const Color(0xFFDAB5C2),
    ]);
    expect(InkColorPreset.green.colors, [
      const Color(0xFF1F3027),
      const Color(0xFF76A58D),
      const Color(0xFFB0D2BF),
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
      final light = preset.colors
          .map((color) => HSLColor.fromColor(color).lightness)
          .toList();
      final dark = preset.colors
          .map((color) => HSLColor.fromColor(
                AppColors.displayInkColor(color, darkMode: true),
              ).lightness)
          .toList();
      expect(light[0], lessThan(light[1]));
      expect(light[1], lessThan(light[2]));
      expect(dark[0], greaterThan(dark[1]));
      expect(dark[1], greaterThan(dark[2]));
      expect(light[2], lessThan(0.85));
      expect(
        HSLColor.fromColor(
          AppColors.displayInkColor(preset.colors[0], darkMode: true),
        ).lightness,
        greaterThan(0.8),
      );
    }
  });

  test('pen and highlighter share any selected swatch across tool changes',
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
      expect(controller.highlighterColor, InkColorPreset.blue.colors[0]);

      for (final preset in InkColorPreset.values) {
        controller.applyInkColorPreset(preset);
        expect(controller.quickColors, preset.colors);
        expect(controller.penColor, preset.colors[0]);
        expect(controller.highlighterColor, preset.colors[0]);
        controller.setColor(preset.colors[2]);
        controller.setTool(DrawingTool.highlighter);
        expect(controller.inkColor, preset.colors[2]);
        controller.setColor(preset.colors[1]);
        controller.setTool(DrawingTool.pen);
        expect(controller.inkColor, preset.colors[1]);
        expect(controller.highlighterColor, preset.colors[1]);
      }
    } finally {
      controller.dispose();
      await database.close();
    }
  });
}
