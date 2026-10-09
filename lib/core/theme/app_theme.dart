import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  static ThemeData dark() {
    const foreground = AppColors.darkText;
    const background = AppColors.darkBackground;
    const surface = AppColors.darkToolbar;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.darkActive,
      brightness: Brightness.dark,
    ).copyWith(
      primary: foreground,
      onPrimary: background,
      primaryContainer: AppColors.darkActive,
      onPrimaryContainer: foreground,
      secondary: foreground,
      onSecondary: background,
      secondaryContainer: AppColors.darkActive,
      onSecondaryContainer: foreground,
      surface: background,
      onSurface: foreground,
      surfaceContainerLowest: surface,
      surfaceContainerLow: surface,
      surfaceContainer: AppColors.darkActive,
      surfaceContainerHigh: AppColors.darkActive,
      surfaceContainerHighest: AppColors.darkPaper,
      outline: AppColors.darkOutline,
      outlineVariant: AppColors.darkOutline,
    );
    return ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'Georgia',
      fontFamilyFallback: const ['Times New Roman', 'Noto Serif', 'serif'],
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      cardColor: AppColors.darkPaper,
      canvasColor: surface,
      dividerColor: AppColors.darkOutline,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: foreground,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: foreground,
        inactiveTrackColor: AppColors.darkActive,
        thumbColor: foreground,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: foreground,
        linearTrackColor: AppColors.darkActive,
      ),
    );
  }

  static ThemeData light({
    AppAccentColor accentColor = AppAccentColor.softBubblegum,
  }) {
    final palette = accentColor.palette;
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.divider,
          surface: AppColors.background,
        ).copyWith(
          primary: AppColors.divider,
          onPrimary: AppColors.inkBlack,
          primaryContainer: palette.primaryContainer,
          onPrimaryContainer: AppColors.inkBlack,
          secondary: palette.accentDark,
          onSecondary: AppColors.inkBlack,
          secondaryContainer: palette.accentLight,
          onSecondaryContainer: AppColors.inkBlack,
          surface: AppColors.background,
          onSurface: AppColors.inkBlack,
          surfaceContainerLowest: AppColors.toolbar,
          surfaceContainerLow: AppColors.toolbar,
          surfaceContainer: AppColors.background,
          surfaceContainerHigh: AppColors.toolbar,
          surfaceContainerHighest: AppColors.divider,
          outline: AppColors.divider,
          outlineVariant: AppColors.divider,
        );

    return ThemeData(
      fontFamily: 'Georgia',
      fontFamilyFallback: const ['Times New Roman', 'Noto Serif', 'serif'],
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.toolbar,
        elevation: 0,
      ),
      dividerColor: AppColors.divider,
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.divider,
        inactiveTrackColor: AppColors.toolbar,
        thumbColor: AppColors.divider,
        overlayColor: AppColors.divider.withValues(alpha: 0.18),
        activeTickMarkColor: AppColors.toolbar,
        inactiveTickMarkColor: AppColors.divider,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.divider,
        linearTrackColor: AppColors.toolbar,
      ),
    );
  }
}
