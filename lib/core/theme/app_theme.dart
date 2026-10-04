import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  static ThemeData light({
    AppAccentColor accentColor = AppAccentColor.softBubblegum,
  }) {
    return ThemeData(
      fontFamily: 'Georgia',
      fontFamilyFallback: const ['Times New Roman', 'Noto Serif', 'serif'],
      colorScheme: ColorScheme.fromSeed(
        seedColor: accentColor.color,
        surface: AppColors.paper,
      ),
      scaffoldBackgroundColor: AppColors.paper,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.toolbar,
        elevation: 0,
      ),
      dividerColor: AppColors.divider,
    );
  }
}
