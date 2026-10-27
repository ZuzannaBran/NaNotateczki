import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/features/planner/presentation/planner_screen.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

void main() {
  final day = DateTime(2026, 10, 20);

  StudySession session(String id, int hour, int minute, int duration) =>
      StudySession(
        id: id,
        title: id,
        scheduledAt: DateTime(day.year, day.month, day.day, hour, minute),
        minutes: duration,
      );

  test('simultaneous and chained sessions receive separate lanes', () {
    final placements = calendarSessionPlacements([
      session('a', 9, 0, 120),
      session('b', 9, 30, 60),
      session('c', 9, 45, 30),
      session('d', 10, 30, 30),
      session('e', 11, 0, 60),
    ], day);
    final byId = {
      for (final placement in placements) placement.session.id: placement,
    };

    expect(byId['a']!.lane, 0);
    expect(byId['b']!.lane, 1);
    expect(byId['c']!.lane, 2);
    expect(byId['d']!.lane, 1);
    for (final id in ['a', 'b', 'c', 'd']) {
      expect(byId[id]!.laneCount, 3);
    }
    expect(byId['e']!.lane, 0);
    expect(byId['e']!.laneCount, 1);
  });

  test('sessions touching at boundaries keep their full width', () {
    final placements = calendarSessionPlacements([
      session('one', 12, 0, 30),
      session('two', 12, 30, 30),
    ], day);
    expect(placements.map((item) => item.laneCount), [1, 1]);
  });

  test('cross-midnight sessions share lanes on the next day', () {
    final overnight = session('overnight', 23, 30, 90);
    final nextDay = DateTime(2026, 10, 21);
    final early = StudySession(
      id: 'early',
      title: 'Early',
      scheduledAt: DateTime(2026, 10, 21, 0, 15),
      minutes: 45,
    );
    final placements = calendarSessionPlacements([overnight, early], nextDay);
    expect(placements.length, 2);
    expect(placements.map((item) => item.laneCount), [2, 2]);
    expect(placements.first.span.top, 0);
    expect(placements.first.span.height, 64);
  });

  testWidgets('week and day render overlapping sessions side by side', (
    tester,
  ) async {
    final planner = StudyPlannerController(
      autoTick: false,
      read: (_) async => null,
      write: (_, _) async {},
    );
    addTearDown(planner.dispose);
    await planner.load();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final today = DateUtils.dateOnly(DateTime.now());
    final first = planner.create(
      title: 'First',
      scheduledAt: DateTime(today.year, today.month, today.day, 9),
      minutes: 90,
    );
    final second = planner.create(
      title: 'Second',
      scheduledAt: DateTime(today.year, today.month, today.day, 9, 30),
      minutes: 60,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: PlannerScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final key = '${today.year}-${today.month}-${today.day}';
    Rect tile(String id, {required bool week}) {
      final suffix = week ? '-$key' : '';
      return tester.getRect(
        find.byKey(ValueKey('planner-time-position:$id$suffix')),
      );
    }

    void expectSideBySide(bool week) {
      final a = tile(first.id, week: week);
      final b = tile(second.id, week: week);
      expect(a.top, lessThan(b.top));
      expect(a.right, lessThanOrEqualTo(b.left));
      expect(a.width, greaterThan(0));
      expect(b.width, greaterThan(0));
    }

    expectSideBySide(true);
    await tester.tap(find.text('Day').last);
    await tester.pumpAndSettle();
    expectSideBySide(false);
    expect(tester.takeException(), isNull);
    await planner.flush();
  });

  test('month focus keeps 27 October visible on desktop and phone', () {
    final month = DateTime(2026, 10, 27);
    final offset = monthCalendarFocusOffset(
      month: month,
      today: month,
      width: 980,
      viewportHeight: 400,
      compact: false,
    );
    expect(offset, closeTo(40 + 5 * (980 / 7 / 1.1) - 400 + 12, 0.001));
    expect(
      monthCalendarFocusOffset(
        month: month,
        today: DateTime(2026, 10, 1),
        width: 980,
        viewportHeight: 400,
        compact: false,
      ),
      0,
    );
    expect(
      monthCalendarFocusOffset(
        month: month,
        today: month,
        width: 390,
        viewportHeight: 400,
        compact: true,
      ),
      27 * 168 - 400 + 12,
    );
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets('month opens with the current day on screen at $width', (
      tester,
    ) async {
      final planner = StudyPlannerController(
        autoTick: false,
        read: (_) async => null,
        write: (_, _) async {},
      );
      addTearDown(planner.dispose);
      await planner.load();
      await tester.binding.setSurfaceSize(Size(width, 610));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<StudyPlannerController>.value(
          value: planner,
          child: const MaterialApp(home: PlannerScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final currentDay = find.byKey(
        ValueKey('planner-day-cell-${now.year}-${now.month}-${now.day}'),
      );
      final scrollViewport = find.byKey(
        ValueKey(width < 960 ? 'mobile-planner-days' : 'planner-month-scroll'),
      );
      expect(currentDay, findsOneWidget);
      expect(scrollViewport, findsOneWidget);
      final cell = tester.getRect(currentDay);
      final viewport = tester.getRect(scrollViewport);
      expect(cell.top, greaterThanOrEqualTo(viewport.top - 1));
      expect(cell.bottom, lessThanOrEqualTo(viewport.bottom + 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('week and month outline remains above clipped cells', (
    tester,
  ) async {
    final planner = StudyPlannerController(
      autoTick: false,
      read: (_) async => null,
      write: (_, _) async {},
    );
    addTearDown(planner.dispose);
    await planner.load();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: PlannerScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final week = tester.widget<Container>(
      find.byKey(const ValueKey('planner-week-frame-outline')),
    );
    final weekBorder = week.foregroundDecoration! as BoxDecoration;
    expect(weekBorder.borderRadius, BorderRadius.circular(12));
    expect(weekBorder.border, isNotNull);

    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    final month = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('planner-month-frame')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Container && widget.foregroundDecoration != null,
            ),
          )
          .first,
    );
    final monthBorder = month.foregroundDecoration! as BoxDecoration;
    expect(monthBorder.borderRadius, BorderRadius.circular(12));
    expect(monthBorder.border, isNotNull);
    expect(tester.takeException(), isNull);
    await planner.flush();
  });
}
