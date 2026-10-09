import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Muted beige actions with legible text and no dark button fills.
class StudyActionStyles {
  static const Color primaryColor = Color(0xFFC4BBAF);
  static const Color secondaryColor = Color(0xFFE4E2DD);
  static const Color borderColor = Color(0xFFB3AB9F);

  static final ButtonStyle primary = FilledButton.styleFrom(
    backgroundColor: primaryColor,
    foregroundColor: AppColors.inkBlack,
    textStyle: const TextStyle(fontWeight: FontWeight.w600),
  );
}

/// Highlights only pale actions while keeping regular controls understated.
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
            side: const BorderSide(
              color: StudyActionStyles.borderColor,
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
            foregroundColor: const WidgetStatePropertyAll(
              AppColors.inkBlack,
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? StudyActionStyles.primaryColor
                  : StudyActionStyles.secondaryColor,
            ),
            side: const WidgetStatePropertyAll(
              BorderSide(
                color: StudyActionStyles.borderColor,
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
