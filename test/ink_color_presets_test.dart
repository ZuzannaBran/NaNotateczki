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
      const Color(0xFF03223A),
      const Color(0xFF083F69),
      const Color(0xFF7DADC8),
    ]);
    expect(InkColorPreset.pink.colors, [
      const Color(0xFF823C44),
      const Color(0xFFD8798A),
      const Color(0xFFEAA6AE),
    ]);
    expect(InkColorPreset.green.colors, [
      const Color(0xFF273526),
      const Color(0xFF45624E),
      const Color(0xFFCADFB8),
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
          .map(
            (color) => HSLColor.fromColor(
              AppColors.displayInkColor(color, darkMode: true),
            ).lightness,
          )
          .toList();
      expect(light[0], lessThan(light[1]));
      expect(light[1], lessThan(light[2]));
      expect(dark[0], greaterThan(dark[1]));
      expect(dark[1], greaterThan(dark[2]));
      double contrast(Color first, Color second) {
        final a = first.computeLuminance();
        final b = second.computeLuminance();
        final greater = a > b ? a : b;
        final smaller = a > b ? b : a;
        return (greater + 0.05) / (smaller + 0.05);
      }

      final lightContrast = preset.colors
          .map((color) => contrast(color, AppColors.paper))
          .toList();
      final darkContrast = preset.colors
          .map(
            (color) => contrast(
              AppColors.displayInkColor(color, darkMode: true),
              AppColors.darkCanvas,
            ),
          )
          .toList();
      expect(lightContrast[0], greaterThan(lightContrast[1]));
      expect(lightContrast[1], greaterThan(lightContrast[2]));
      for (final ratio in darkContrast) {
        expect(ratio, greaterThan(1));
      }
      expect(
        HSLColor.fromColor(
          AppColors.displayInkColor(preset.colors[0], darkMode: true),
        ).lightness,
        greaterThan(0.6),
      );
    }
  });

  test('swatches 2 and 3 darken in light and brighten in dark', () {
    const previous = <InkColorPreset, List<Color>>{
      InkColorPreset.blue: [
        Color(0xFF1A2130),
        Color(0xFFACBED8),
        Color(0xFFDEE7F2),
      ],
      InkColorPreset.pink: [
        Color(0xFF3A212B),
        Color(0xFFDAB5C2),
        Color(0xFFF2E1E8),
      ],
      InkColorPreset.green: [
        Color(0xFF1F3027),
        Color(0xFFB0D2BF),
        Color(0xFFE4EFE8),
      ],
    };
    for (final entry in previous.entries) {
      final updated = entry.key.colors;
      for (final index in [1, 2]) {
        expect(
          updated[index].computeLuminance(),
          lessThan(entry.value[index].computeLuminance()),
        );
        expect(
          AppColors.displayInkColor(
            updated[index],
            darkMode: true,
          ).computeLuminance(),
          greaterThan(
            AppColors.displayInkColor(
              entry.value[index],
              darkMode: true,
            ).computeLuminance(),
          ),
        );
      }
    }
  });

  test(
    'pen and highlighter share any selected swatch across tool changes',
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
    },
  );
}
