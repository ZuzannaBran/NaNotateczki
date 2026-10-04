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
  AppAccentColor.bubblegum,
  AppAccentColor.softBubblegum,
  AppAccentColor.lavender,
  AppAccentColor.peach,
  AppAccentColor.babyBlue,
];

extension AppAccentColorX on AppAccentColor {
  String get label {
    return switch (this) {
      AppAccentColor.classic => 'Classic',
      AppAccentColor.sakura => 'Sakura',
      AppAccentColor.bubblegum => 'Cherry',
      AppAccentColor.softBubblegum => 'Bubblegum',
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
      AppAccentColor.bubblegum => const Color(0xFFE05278),
      AppAccentColor.softBubblegum => const Color(0xFFFFC1CC),
      AppAccentColor.lavender => const Color(0xFFCA9BF7),
      AppAccentColor.peach => const Color(0xFFFFAB91),
      AppAccentColor.mint => const Color(0xFF80CBC4),
      AppAccentColor.babyBlue => const Color(0xFF77C3EC),
    };
  }

  AppAccentPalette get palette {
    return switch (this) {
      AppAccentColor.bubblegum => _cherryPalette,
      AppAccentColor.softBubblegum => _bubblegumPalette,
      AppAccentColor.lavender => _lavenderPalette,
      AppAccentColor.peach => _peachPalette,
      AppAccentColor.babyBlue => _babyBluePalette,
      _ => _bubblegumPalette,
    };
  }
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

const _cherryPalette = AppAccentPalette(
  accentDark: Color(0xFFCF4065),
  accentLight: Color(0xFFE77593),
  primaryContainer: Color(0xFFF2B6C6),
  background: AppColors.background,
  divider: AppColors.divider,
);

const _bubblegumPalette = AppAccentPalette(
  accentDark: Color(0xFFD9A4AD),
  accentLight: Color(0xFFFFCAD4),
  primaryContainer: Color(0xFFFFD2DA),
  background: AppColors.background,
  divider: AppColors.divider,
);

const _lavenderPalette = AppAccentPalette(
  accentDark: Color(0xFFA352F1),
  accentLight: Color(0xFFD4ADF8),
  primaryContainer: Color(0xFFDDBFFA),
  background: AppColors.background,
  divider: AppColors.divider,
);

const _peachPalette = AppAccentPalette(
  accentDark: Color(0xFFFF7E56),
  accentLight: Color(0xFFFFBEAB),
  primaryContainer: Color(0xFFFFD2C4),
  background: AppColors.background,
  divider: AppColors.divider,
);

const _babyBluePalette = AppAccentPalette(
  accentDark: Color(0xFF43ACE5),
  accentLight: Color(0xFF99D2F1),
  primaryContainer: Color(0xFFBCE1F6),
  background: AppColors.background,
  divider: AppColors.divider,
);

class AppColors {
  static const background = Color(0xFFF7F3EE);
  static const toolbar = Color(0xFFE9E7E4);
  static const paper = Color(0xFFF8F6F2);
  static const inkBlack = Color(0xFF1E1E1E);
  static const shadow = Color(0x22000000);
  static const divider = Color(0xFFCCC9C9);

  static const inkPalette = <Color>[
    inkBlack,
    Color(0xFF2E5AAC),
    Color(0xFFB33636),
    Color(0xFF2E7D32),
    Color(0xFF6A4C93),
    Color(0xFFB9792A),
  ];
}
