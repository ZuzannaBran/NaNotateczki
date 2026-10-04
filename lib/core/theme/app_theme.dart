import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  static ThemeData light({
    AppAccentColor accentColor = AppAccentColor.softBubblegum,
  }) {
    final palette = accentColor.palette;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accentColor.color,
      surface: AppColors.background,
    ).copyWith(
      primaryContainer: palette.primaryContainer,
      onPrimaryContainer: AppColors.inkBlack,
      secondary: palette.accentDark,
      onSecondary: AppColors.inkBlack,
      secondaryContainer: palette.accentLight,
      onSecondaryContainer: AppColors.inkBlack,
      surface: AppColors.background,
      surfaceContainerLowest: AppColors.toolbar,
      surfaceContainerLow: AppColors.toolbar,
      outlineVariant: AppColors.divider,
    );

    return ThemeData(
      fontFamily: 'Georgia',
      fontFamilyFallback: const ['Times New Roman', 'Noto Serif', 'serif'],
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.toolbar,
        elevation: 0,
      ),
      dividerColor: AppColors.divider,
    );
  }
}
