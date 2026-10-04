import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  static ThemeData light({
    AppAccentColor accentColor = AppAccentColor.softBubblegum,
  }) {
    final palette = accentColor.palette;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accentColor.color,
      surface: palette.background,
    ).copyWith(
      primaryContainer: palette.primaryContainer,
      onPrimaryContainer: AppColors.inkBlack,
      secondary: palette.accentDark,
      onSecondary: AppColors.inkBlack,
      secondaryContainer: palette.accentLight,
      onSecondaryContainer: AppColors.inkBlack,
      surface: palette.background,
      surfaceContainerLowest: palette.background,
      surfaceContainerLow: palette.surfaceContainerLow,
      surfaceContainer: palette.surfaceContainer,
      surfaceContainerHigh: palette.surfaceContainerHigh,
      surfaceContainerHighest: palette.surfaceContainerHighest,
      outlineVariant: palette.divider,
    );

    return ThemeData(
      fontFamily: 'Georgia',
      fontFamilyFallback: const ['Times New Roman', 'Noto Serif', 'serif'],
      colorScheme: colorScheme,
      scaffoldBackgroundColor: palette.background,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: palette.surfaceContainerLow,
        elevation: 0,
      ),
      dividerColor: palette.divider,
    );
  }
}
