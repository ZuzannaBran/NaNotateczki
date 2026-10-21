import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Muted actions retain the app palette and typography in both visual modes.
class StudyActionStyles {
  static const Color primaryColor = AppColors.divider;
  static const Color secondaryColor = AppColors.toolbar;
  static const Color borderColor = AppColors.divider;
  static const double sessionButtonHeight = 32;
  static const sessionButtonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
  );
  static const sessionButtonPadding = EdgeInsets.symmetric(
    horizontal: 8,
    vertical: 4,
  );

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

  static Color plannedSessionColor(ThemeData theme) =>
      theme.brightness == Brightness.dark
      ? theme.colorScheme.surfaceContainerHighest
      : theme.colorScheme.surface;

  static Color sessionCardColor(
    ThemeData theme,
    int? colorValue, {
    Color? baseColor,
  }) {
    final base = baseColor ?? plannedSessionColor(theme);
    if (colorValue == null) {
      return base;
    }
    return Color.alphaBlend(
      Color(
        colorValue,
      ).withValues(alpha: theme.brightness == Brightness.dark ? 0.45 : 0.32),
      base,
    );
  }

  static RoundedRectangleBorder sessionCardShape(ColorScheme colors) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.onSurface),
      );

  static ButtonStyle primary(ThemeData theme) => FilledButton.styleFrom(
    shape: sessionButtonShape,
    overlayColor: theme.colorScheme.outline.withValues(alpha: 0.16),
    backgroundColor: background(theme, selected: true),
    foregroundColor: foreground(theme),
    textStyle: theme.textTheme.labelLarge!.copyWith(
      fontWeight: FontWeight.w600,
    ),
  );

  static ButtonStyle sessionPrimary(ThemeData theme) => primary(theme).copyWith(
    shape: const WidgetStatePropertyAll(sessionButtonShape),
    padding: const WidgetStatePropertyAll(sessionButtonPadding),
  );

  static ButtonStyle sessionOutlined() => OutlinedButton.styleFrom(
    shape: sessionButtonShape,
    padding: sessionButtonPadding,
  );

  static Widget sessionButtonContent({
    required IconData icon,
    required String label,
    Key? contentKey,
  }) => Center(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        key: contentKey,
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 18), const SizedBox(width: 4), Text(label)],
      ),
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
            shape: StudyActionStyles.sessionButtonShape,
            foregroundColor: foreground,
            textStyle: labelStyle,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: StudyActionStyles.sessionButtonShape,
            foregroundColor: foreground,
            overlayColor: theme.colorScheme.outline.withValues(alpha: 0.16),
            side: BorderSide(color: outline),
            textStyle: labelStyle,
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(foregroundColor: foreground),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            shape: const WidgetStatePropertyAll(
              StudyActionStyles.sessionButtonShape,
            ),
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
