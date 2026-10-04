import 'package:flutter/material.dart';

enum AppAccentColor {
  classic,
  sakura,
  bubblegum,
  lavender,
  peach,
  mint,
  babyBlue,
}

const selectableAppAccentColors = <AppAccentColor>[
  AppAccentColor.bubblegum,
  AppAccentColor.lavender,
  AppAccentColor.peach,
  AppAccentColor.babyBlue,
];

extension AppAccentColorX on AppAccentColor {
  String get label {
    return switch (this) {
      AppAccentColor.classic => 'Classic',
      AppAccentColor.sakura => 'Sakura',
      AppAccentColor.bubblegum => 'Bubblegum',
      AppAccentColor.lavender => 'Lavender',
      AppAccentColor.peach => 'Peach',
      AppAccentColor.mint => 'Mint',
      AppAccentColor.babyBlue => 'Baby blue',
    };
  }

  Color get color {
    return switch (this) {
      AppAccentColor.classic => AppColors.inkBlack,
      AppAccentColor.sakura => const Color(0xFFF48FB1),
      AppAccentColor.bubblegum => const Color(0xFFFF80AB),
      AppAccentColor.lavender => const Color(0xFFB39DDB),
      AppAccentColor.peach => const Color(0xFFFFAB91),
      AppAccentColor.mint => const Color(0xFF80CBC4),
      AppAccentColor.babyBlue => const Color(0xFF90CAF9),
    };
  }
}

class AppColors {
  static const paper = Color(0xFFF8F6F2);
  static const toolbar = Color(0xFFF1EEE8);
  static const inkBlack = Color(0xFF1E1E1E);
  static const shadow = Color(0x22000000);
  static const divider = Color(0xFFE4E0D8);

  static const inkPalette = <Color>[
    inkBlack,
    Color(0xFF2E5AAC),
    Color(0xFFB33636),
    Color(0xFF2E7D32),
    Color(0xFF6A4C93),
    Color(0xFFB9792A),
  ];
}
