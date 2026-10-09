import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Strong, neutral action contrast without changing the rest of the app.
class StudyActionStyles {
  static const Color primaryColor = Color(0xFF514A41);
  static const Color secondaryColor = Color(0xFFD7D2C8);
  static const Color borderColor = Color(0xFF82786C);

  static final ButtonStyle primary = FilledButton.styleFrom(
    backgroundColor: primaryColor,
    foregroundColor: AppColors.paper,
    textStyle: const TextStyle(fontWeight: FontWeight.w600),
  );

  static final ButtonStyle secondary = FilledButton.styleFrom(
    backgroundColor: secondaryColor,
    foregroundColor: AppColors.inkBlack,
    textStyle: const TextStyle(fontWeight: FontWeight.w600),
  );

  static final ButtonStyle icon = IconButton.styleFrom(
    backgroundColor: secondaryColor,
    foregroundColor: AppColors.inkBlack,
  );
}

/// Keeps enabled actions clearly darker than truly disabled controls.
class StudyActionTheme extends StatelessWidget {
  const StudyActionTheme({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.inkBlack,
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.inkBlack,
            backgroundColor: StudyActionStyles.secondaryColor,
            side: const BorderSide(
              color: StudyActionStyles.borderColor,
              width: 1.15,
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: AppColors.inkBlack,
          ),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? AppColors.paper
                  : AppColors.inkBlack,
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? StudyActionStyles.primaryColor
                  : StudyActionStyles.secondaryColor,
            ),
            side: const WidgetStatePropertyAll(
              BorderSide(
                color: StudyActionStyles.borderColor,
                width: 1.15,
              ),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        chipTheme: theme.chipTheme.copyWith(
          backgroundColor: StudyActionStyles.secondaryColor,
          labelStyle: const TextStyle(
            color: AppColors.inkBlack,
            fontWeight: FontWeight.w600,
          ),
          side: const BorderSide(
            color: StudyActionStyles.borderColor,
          ),
        ),
      ),
      child: child,
    );
  }
}
