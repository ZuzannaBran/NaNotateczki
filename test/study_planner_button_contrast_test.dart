import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/features/planner/presentation/study_action_theme.dart';

void main() {
  for (final darkMode in [false, true]) {
    testWidgets('planner controls retain app typography in dark=$darkMode', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: darkMode ? AppTheme.dark() : AppTheme.light(),
          home: StudyActionTheme(
            child: Scaffold(
              body: Column(
                children: [
                  FilledButton(onPressed: () {}, child: const Text('Primary')),
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('Outline'),
                  ),
                  TextButton(onPressed: () {}, child: const Text('Text')),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('Today')),
                      ButtonSegment(value: 1, label: Text('Week')),
                    ],
                    selected: const {0},
                    onSelectionChanged: (_) {},
                  ),
                  const Chip(label: Text('Technique')),
                ],
              ),
            ),
          ),
        ),
      );
      for (final label in [
        'Primary',
        'Outline',
        'Text',
        'Today',
        'Week',
        'Technique',
      ]) {
        expect(
          DefaultTextStyle.of(
            tester.element(find.text(label)),
          ).style.fontFamily,
          'Georgia',
          reason: '$label must inherit the application typography',
        );
      }
    });
  }

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

    final primary = StudyActionStyles.primary(scopedTheme);
    expect(
      primary.backgroundColor!.resolve(<WidgetState>{}),
      StudyActionStyles.primaryColor,
    );
    expect(
      primary.foregroundColor!.resolve(<WidgetState>{}),
      AppColors.inkBlack,
    );
    expect(StudyActionStyles.secondaryColor, AppColors.toolbar);
    expect(
      StudyActionStyles.primaryColor.computeLuminance(),
      greaterThan(0.45),
    );
    expect(
      StudyActionStyles.primaryColor,
      isNot(StudyActionStyles.secondaryColor),
    );
    expect(
      scopedTheme.textButtonTheme.style!.foregroundColor!.resolve(
        <WidgetState>{},
      ),
      AppColors.inkBlack,
    );
    expect(
      scopedTheme.outlinedButtonTheme.style!.foregroundColor!.resolve(
        <WidgetState>{},
      ),
      AppColors.inkBlack,
    );
    expect(scopedTheme.outlinedButtonTheme.style!.backgroundColor, isNull);
    expect(scopedTheme.iconButtonTheme.style!.backgroundColor, isNull);

    final segmented = scopedTheme.segmentedButtonTheme.style!;
    expect(
      segmented.backgroundColor!.resolve(<WidgetState>{WidgetState.selected}),
      StudyActionStyles.primaryColor,
    );
    expect(
      segmented.backgroundColor!.resolve(<WidgetState>{}),
      StudyActionStyles.secondaryColor,
    );
    expect(
      segmented.foregroundColor!.resolve(<WidgetState>{WidgetState.selected}),
      AppColors.inkBlack,
    );
    expect(
      segmented.foregroundColor!.resolve(<WidgetState>{}),
      AppColors.inkBlack,
    );
  });
}
