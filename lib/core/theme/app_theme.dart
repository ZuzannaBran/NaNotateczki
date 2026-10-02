import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  static ThemeData light({
    AppAccentColor accentColor = AppAccentColor.classic,
  }) {
    final seedColor = accentColor.color;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      surface: AppColors.paper,
    );

    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.paper,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: Color.lerp(AppColors.toolbar, seedColor, 0.08),
        elevation: 0,
      ),
      dividerColor: AppColors.divider,
    );
  }
}
