import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Muted actions retain the app palette and typography in both visual modes.
class StudyActionStyles {
  static const Color primaryColor = Color(0xFFC4BBAF);
  static const Color secondaryColor = Color(0xFFE4E2DD);
  static const Color borderColor = Color(0xFFB3AB9F);

  static Color background(ThemeData theme, {bool selected = false}) {
    if (theme.brightness == Brightness.dark) {
      return selected
          ? theme.colorScheme.surfaceContainerHigh
          : theme.colorScheme.surfaceContainerLow;
    }
    return selected ? primaryColor : secondaryColor;
  }

  static Color foreground(ThemeData theme) =>
      theme.brightness == Brightness.dark
      ? theme.colorScheme.onSurface
      : AppColors.inkBlack;

  static Color outline(ThemeData theme) => theme.brightness == Brightness.dark
      ? theme.colorScheme.outline
      : borderColor;

  static ButtonStyle primary(ThemeData theme) => FilledButton.styleFrom(
    backgroundColor: background(theme, selected: true),
    foregroundColor: foreground(theme),
    textStyle: theme.textTheme.labelLarge!.copyWith(
      fontWeight: FontWeight.w600,
    ),
  );
}

/// Highlights only pale actions while keeping regular controls understated.
class StudyActionTheme extends StatelessWidget {
  const StudyActionTheme({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = StudyActionStyles.foreground(theme);
    final outline = StudyActionStyles.outline(theme);
    final labelStyle = theme.textTheme.labelLarge!.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Theme(
      data: theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: StudyActionStyles.primary(theme),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            textStyle: labelStyle,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: foreground,
            side: BorderSide(color: outline),
            textStyle: labelStyle,
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(foregroundColor: foreground),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(foreground),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => StudyActionStyles.background(
                theme,
                selected: states.contains(WidgetState.selected),
              ),
            ),
            side: WidgetStatePropertyAll(BorderSide(color: outline)),
            textStyle: WidgetStatePropertyAll(labelStyle),
          ),
        ),
        chipTheme: theme.chipTheme.copyWith(
          backgroundColor: StudyActionStyles.background(theme),
          selectedColor: StudyActionStyles.background(theme, selected: true),
          labelStyle: labelStyle.copyWith(color: foreground),
          side: BorderSide(color: outline),
        ),
      ),
      child: child,
    );
  }
}
