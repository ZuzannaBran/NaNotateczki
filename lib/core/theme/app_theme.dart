import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  static ThemeData light({
    AppAccentColor accentColor = AppAccentColor.classic,
  }) {
    return ThemeData(
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
