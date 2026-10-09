import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/features/planner/presentation/study_action_theme.dart';

void main() {
  testWidgets('study controls distinguish active from inactive appearances', (
    tester,
  ) async {
    late ThemeData scopedTheme;

    await tester.pumpWidget(
      MaterialApp(
        home: StudyActionTheme(
          child: Builder(
            builder: (context) {
              scopedTheme = Theme.of(context);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      ),
    );

    final primary = StudyActionStyles.primary;
    expect(
      primary.backgroundColor!.resolve(<WidgetState>{}),
      StudyActionStyles.primaryColor,
    );
    expect(
      primary.foregroundColor!.resolve(<WidgetState>{}),
      AppColors.paper,
    );
    expect(
      StudyActionStyles.secondary.backgroundColor!.resolve(<WidgetState>{}),
      StudyActionStyles.secondaryColor,
    );
    expect(
      StudyActionStyles.primaryColor,
      isNot(StudyActionStyles.secondaryColor),
    );
    expect(
      scopedTheme.textButtonTheme.style!.foregroundColor!
          .resolve(<WidgetState>{}),
      AppColors.inkBlack,
    );
    expect(
      scopedTheme.outlinedButtonTheme.style!.foregroundColor!
          .resolve(<WidgetState>{}),
      AppColors.inkBlack,
    );

    final segmented = scopedTheme.segmentedButtonTheme.style!;
    expect(
      segmented.backgroundColor!
          .resolve(<WidgetState>{WidgetState.selected}),
      StudyActionStyles.primaryColor,
    );
    expect(
      segmented.backgroundColor!.resolve(<WidgetState>{}),
      StudyActionStyles.secondaryColor,
    );
    expect(
      segmented.foregroundColor!
          .resolve(<WidgetState>{WidgetState.selected}),
      AppColors.paper,
    );
    expect(
      segmented.foregroundColor!.resolve(<WidgetState>{}),
      AppColors.inkBlack,
    );
  });
}
