import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  static ThemeData light() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.inkBlack,
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
