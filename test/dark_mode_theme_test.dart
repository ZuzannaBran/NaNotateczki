import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';

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
  });

  test('dark mode is initially off for existing preferences', () {
    final preferences = AppPreferencesController();
    expect(preferences.darkMode, isFalse);
    preferences.dispose();
  });
}
