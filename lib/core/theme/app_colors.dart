import 'package:flutter/material.dart';

enum AppAccentColor {
  classic,
  sakura,
  bubblegum,
  lavender,
  peach,
  mint,
  babyBlue,
  softBubblegum,
}

const selectableAppAccentColors = <AppAccentColor>[
  AppAccentColor.softBubblegum,
];

extension AppAccentColorX on AppAccentColor {
  String get label => 'Beige';

  Color get color => AppColors.divider;

  AppAccentPalette get palette => _beigePalette;
}

class AppAccentPalette {
  const AppAccentPalette({
    required this.accentDark,
    required this.accentLight,
    required this.primaryContainer,
    required this.background,
    required this.divider,
  });

  final Color accentDark;
  final Color accentLight;
  final Color primaryContainer;
  final Color background;
  final Color divider;
}

const _beigePalette = AppAccentPalette(
  accentDark: AppColors.divider,
  accentLight: AppColors.toolbar,
  primaryContainer: AppColors.toolbar,
  background: AppColors.background,
  divider: AppColors.divider,
);

class AppColors {
  // Warm beige UI palette.
  static const background = Color(0xFFF1F0EC);
  static const toolbar = Color(0xFFE4E2DD);
  static const paper = Color(0xFFFAF9F6);
  static const inkBlack = Color(0xFF2B2B29);
  static const shadow = Color(0x22000000);
  static const divider = Color(0xFFCFCCC5);
  static const overviewViewport = Color(0xFFE8E0D2);

  static const inkPalette = <Color>[
    inkBlack,
    Color(0xFF2E5AAC),
    Color(0xFFB33636),
    Color(0xFF2E7D32),
    Color(0xFF6A4C93),
    Color(0xFFB9792A),
  ];
}
