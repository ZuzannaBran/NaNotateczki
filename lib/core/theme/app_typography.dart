import 'package:flutter/material.dart';

/// Shared typography for application UI; document content is independent.
class AppTypography {
  /// Bundled Georgia-like font, consistent across web and desktop.
  static const String fontFamily = 'Gelasio';
  static const List<String> fontFamilyFallback = [
    'Georgia',
    'Noto Serif',
    'DejaVu Serif',
    'Liberation Serif',
    'Times New Roman',
    'serif',
  ];

  static const double heading = 18;
  static const double folder = 16;
  static const double document = 14;
  static const double small = 12;

  static ThemeData apply(ThemeData theme) {
    final text = theme.textTheme.apply(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
    return theme.copyWith(
      primaryTextTheme: theme.primaryTextTheme.apply(
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
      ),
      textTheme: text.copyWith(
        displayLarge: text.displayLarge?.copyWith(fontSize: heading),
        displayMedium: text.displayMedium?.copyWith(fontSize: heading),
        displaySmall: text.displaySmall?.copyWith(fontSize: heading),
        headlineLarge: text.headlineLarge?.copyWith(fontSize: heading),
        headlineMedium: text.headlineMedium?.copyWith(fontSize: heading),
        headlineSmall: text.headlineSmall?.copyWith(fontSize: heading),
        titleLarge: text.titleLarge?.copyWith(fontSize: heading),
        titleMedium: text.titleMedium?.copyWith(fontSize: folder),
        titleSmall: text.titleSmall?.copyWith(fontSize: document),
        bodyLarge: text.bodyLarge?.copyWith(fontSize: document),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: document),
        bodySmall: text.bodySmall?.copyWith(fontSize: small),
        labelLarge: text.labelLarge?.copyWith(fontSize: document),
        labelMedium: text.labelMedium?.copyWith(fontSize: small),
        labelSmall: text.labelSmall?.copyWith(fontSize: small),
      ),
    );
  }
}
