import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/features/planner/presentation/planner_screen.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

const weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

ValueKey<String> dayKey(DateTime day) =>
    ValueKey('planner-day-label-${day.year}-${day.month}-${day.day}');

String shortWeekday(DateTime day) =>
    weekdays[day.weekday - DateTime.monday].substring(0, 3);

void expectCalendarLabel(WidgetTester tester, DateTime day, String label) {
  final finder = find.byKey(dayKey(day));
  expect(finder, findsOneWidget);
  expect(tester.widget<Text>(finder).data, label);
}

void main() {
  testWidgets('weekday names appear in today, week and month cells', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final planner = StudyPlannerController(
      autoTick: false,
      read: (_) async => null,
      write: (_, _) async {},
    );
    await planner.load();

    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: PlannerScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final today = DateUtils.dateOnly(DateTime.now());
    final monday = DateTime(
      today.year, today.month, today.day - today.weekday + DateTime.monday,
    );

    for (var i = 0; i < 7; i++) {
      final date = DateTime(monday.year, monday.month, monday.day + i);
      expectCalendarLabel(tester, date, '${shortWeekday(date)} ${date.day}');
    }

    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();

    final firstOfMonth = DateTime(today.year, today.month);
    final firstMonday = DateTime(
      firstOfMonth.year,
      firstOfMonth.month,
      firstOfMonth.day - firstOfMonth.weekday + DateTime.monday,
    );
    for (var i = 0; i < 7; i++) {
      final date = DateTime(
        firstMonday.year,
        firstMonday.month,
        firstMonday.day + i,
      );
      expectCalendarLabel(tester, date, '${shortWeekday(date)} ${date.day}');
    }

    await tester.tap(find.text('Today').last);
    await tester.pumpAndSettle();
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    expectCalendarLabel(
      tester,
      today,
      '${weekdays[today.weekday - DateTime.monday]} '
      '${today.day} ${months[today.month - 1]}',
    );

    await tester.tap(find.byTooltip('Previous'));
    await tester.pumpAndSettle();
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    expectCalendarLabel(
      tester,
      yesterday,
      '${weekdays[yesterday.weekday - DateTime.monday]} '
      '${yesterday.day} ${months[yesterday.month - 1]}',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await planner.flush();
    planner.dispose();
  });
}
