import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/features/planner/presentation/planner_screen.dart';
import 'package:program/features/planner/presentation/study_action_theme.dart';
import 'package:program/features/planner/presentation/study_timer_widgets.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

void main() {
  Future<StudyPlannerController> loadPlanner() async {
    final planner = StudyPlannerController(
      autoTick: false,
      read: (_) async => null,
      write: (_, _) async {},
    );
    addTearDown(planner.dispose);
    await planner.load();
    return planner;
  }

  testWidgets('calendar changes between today week and month', (tester) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    planner.create(
      title: 'Calculus',
      scheduledAt: DateTime.now(),
      description: 'Integrals',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: PlannerScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Study planner'), findsOneWidget);
    expect(find.textContaining('Calculus'), findsWidgets);

    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^Mon \d+$')), findsWidgets);
    await tester.tap(find.text('Today').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Calculus'), findsWidgets);
    expect(tester.takeException(), isNull);
    await planner.flush();
  });

  testWidgets('phone planner uses vertical days and compact actions', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: PlannerScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mobile-planner-days')), findsOneWidget);
    expect(find.byTooltip('Planner actions'), findsNothing);
    expect(find.byKey(const ValueKey('planner-smart-session')), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-new-session')), findsOneWidget);
    expect(find.byTooltip('Previous'), findsOneWidget);
    expect(find.byTooltip('Next'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-planner-days')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(768, 1024));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-planner-days')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('planner-new-session')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Session name'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Settings'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sidebar session buttons share width and corner shape', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final sidebarWidth in [240.0, 320.0]) {
      await tester.pumpWidget(
        ChangeNotifierProvider<StudyPlannerController>.value(
          value: planner,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: sidebarWidth,
                  child: const StudyTimerCard(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final timer = tester.getRect(
        find.byKey(const ValueKey('study-timer-card')),
      );
      final startFinder = find.byKey(const ValueKey('sidebar-start-session'));
      final smartFinder = find.byKey(const ValueKey('sidebar-smart-session'));
      final start = tester.getRect(startFinder);
      final smart = tester.getRect(smartFinder);

      expect(start.width, closeTo(smart.width, 0.1));
      final startContent = tester.getRect(
        find.byKey(const ValueKey('sidebar-start-session-content')),
      );
      final smartContent = tester.getRect(
        find.byKey(const ValueKey('sidebar-smart-session-content')),
      );
      expect(startContent.center.dx, closeTo(start.center.dx, 1));
      expect(smartContent.center.dx, closeTo(smart.center.dx, 1));
      expect(
        find.descendant(
          of: startFinder,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: smartFinder,
          matching: find.byIcon(Icons.auto_awesome_rounded),
        ),
        findsOneWidget,
      );
      expect(start.height, StudyActionStyles.sessionButtonHeight);
      expect(start.height, 32);
      expect(start.height, closeTo(smart.height, 0.1));
      expect(
        tester.widget<Padding>(
          find.byKey(const ValueKey('study-timer-card')),
        ).padding,
        const EdgeInsets.fromLTRB(14, 20, 14, 22),
      );
      expect(timer.bottom - start.bottom, closeTo(22, 0.1));
      expect(
        start.top -
            tester.getRect(
              find.text('Ready for your next focus session?'),
            ).bottom,
        closeTo(30, 0.1),
      );
      expect(start.top, closeTo(smart.top, 0.1));
      expect(start.left, closeTo(timer.left + 14, 0.1));
      expect(smart.right, closeTo(timer.right - 14, 0.1));
      expect(smart.left - start.right, closeTo(8, 0.1));

      final startButton = tester.widget<FilledButton>(startFinder);
      final smartButton = tester.widget<OutlinedButton>(smartFinder);
      final firstShape = startButton.style!.shape!.resolve({});
      final secondShape = smartButton.style!.shape!.resolve({});
      expect(firstShape, isA<RoundedRectangleBorder>());
      expect(secondShape, isA<RoundedRectangleBorder>());
      expect(
        (firstShape! as RoundedRectangleBorder).borderRadius,
        const BorderRadius.all(Radius.circular(12)),
      );
      expect(
        (secondShape! as RoundedRectangleBorder).borderRadius,
        const BorderRadius.all(Radius.circular(12)),
      );
      expect(tester.takeException(), isNull);
    }
  });

  for (final darkMode in [false, true]) {
    testWidgets('upcoming cards match calendar without lines, dark=$darkMode', (
      tester,
    ) async {
      final planner = await loadPlanner();
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1, 12);
      final first = planner.create(
        title: 'Biology review',
        scheduledAt: tomorrow,
      );
      final second = planner.create(
        title: 'Physics revision',
        scheduledAt: tomorrow.add(const Duration(hours: 1)),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<StudyPlannerController>.value(
          value: planner,
          child: MaterialApp(
            theme: darkMode ? AppTheme.dark() : AppTheme.light(),
            home: Scaffold(
              body: Row(
                children: [
                  const SizedBox(width: 280, child: StudyTimerCard()),
                  const Expanded(child: PlannerScreen()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final timer = find.byKey(const ValueKey('study-timer-card'));
      expect(
        find.descendant(of: timer, matching: find.byType(Divider)),
        findsNothing,
      );
      final upcoming = find.byKey(
        ValueKey('sidebar-upcoming-card:${first.id}'),
      );
      expect(upcoming, findsOneWidget);
      expect(
        find.byKey(ValueKey('sidebar-upcoming-card:${second.id}')),
        findsOneWidget,
      );
      expect(find.text('Biology review'), findsWidgets);
      expect(find.text('Physics revision'), findsOneWidget);

      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();

      final calendar = find.byKey(
        ValueKey('planner-session-tile:${first.id}'),
      );
      expect(calendar, findsOneWidget);
      final sidebarMaterial = tester.widget<Material>(upcoming);
      final calendarMaterial = tester.widget<Material>(calendar);
      expect(sidebarMaterial.color, calendarMaterial.color);
      expect(sidebarMaterial.shape, calendarMaterial.shape);

      await tester.tap(
        find.descendant(
          of: upcoming,
          matching: find.byTooltip('Start scheduled session'),
        ),
      );
      await tester.pump();
      expect(planner.active?.id, first.id);
      expect(tester.takeException(), isNull);
      await planner.flush();
    });
  }

  testWidgets('sidebar timer starts pauses and rates a session', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: Scaffold(body: StudyTimerCard())),
      ),
    );
    await tester.tap(find.text('Start session'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'History lesson',
    );
    await tester.tap(find.text('Save & start'));
    await tester.pumpAndSettle();
    expect(planner.active?.title, 'History lesson');

    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(planner.active?.status, StudyStatus.paused);
    await tester.tap(find.byTooltip('Stop session'));
    await tester.pumpAndSettle();
    expect(find.text('Rate your productivity'), findsOneWidget);
    expect(find.byIcon(Icons.star_border_rounded), findsNWidgets(5));
    expect(find.text('5'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('productivity-5')));
    await tester.pumpAndSettle();
    expect(planner.history.single.productivity, 5);
    expect(tester.takeException(), isNull);
    await planner.flush();
  });

  testWidgets('skipping a rating never leaves a sidebar reminder', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final item = planner.create(
      title: 'Unrated session',
      scheduledAt: DateTime.now(),
    );
    planner.start(item.id);

    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: Scaffold(body: StudyTimerCard())),
      ),
    );
    await tester.tap(find.byTooltip('Stop session'));
    await tester.pumpAndSettle();
    expect(find.text('Rate your productivity'), findsOneWidget);

    await tester.tap(find.text('Skip rating'));
    await tester.pumpAndSettle();
    expect(planner.pendingReviews, isEmpty);
    expect(planner.history.single.id, item.id);
    expect(planner.history.single.productivity, isNull);
    expect(find.textContaining('Rate'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await planner.flush();
  });

  testWidgets('closing the rating dialog also finishes without rating', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final item = planner.create(
      title: 'Dismissed session',
      scheduledAt: DateTime.now(),
    );
    planner.start(item.id);

    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: Scaffold(body: StudyTimerCard())),
      ),
    );
    await tester.tap(find.byTooltip('Stop session'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(planner.pendingReviews, isEmpty);
    expect(planner.history.single.id, item.id);
    expect(planner.history.single.productivity, isNull);
    expect(find.text('Rate your productivity'), findsNothing);
    await planner.flush();
  });

  testWidgets('calendar shows completed session ratings without history', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rated = planner.create(
      title: 'Rated study',
      scheduledAt: DateTime.now(),
    );
    planner.start(rated.id);
    planner.stop();
    planner.rate(rated.id, 3);

    final unrated = planner.create(
      title: 'Skipped study',
      scheduledAt: DateTime.now(),
    );
    planner.start(unrated.id);
    planner.stop();
    planner.skipRating(unrated.id);

    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: PlannerScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Study history'), findsNothing);
    expect(find.byTooltip('Settings'), findsNothing);
    expect(find.textContaining('★★★☆☆'), findsWidgets);
    expect(find.textContaining('Not rated'), findsWidgets);
    expect(find.textContaining('null/5'), findsNothing);
    expect(find.textContaining('Rate now'), findsNothing);
    expect(tester.takeException(), isNull);
    await planner.flush();
  });

  for (final darkMode in [false, true]) {
    testWidgets('completed sessions use darker cards in dark=$darkMode', (
      tester,
    ) async {
      final planner = await loadPlanner();
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final finished = planner.create(
        title: 'Finished lesson',
        scheduledAt: DateTime.now(),
      );
      planner.start(finished.id);
      planner.stop();
      planner.rate(finished.id, 4);
      final planned = planner.create(
        title: 'Planned lesson',
        scheduledAt: DateTime.now(),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<StudyPlannerController>.value(
          value: planner,
          child: MaterialApp(
            theme: darkMode ? AppTheme.dark() : AppTheme.light(),
            home: const PlannerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final done = find.byKey(ValueKey('planner-session-tile:${finished.id}'));
      final upcoming = find.byKey(
        ValueKey('planner-session-tile:${planned.id}'),
      );
      final scheme = Theme.of(tester.element(done)).colorScheme;
      final doneColor = tester.widget<Material>(done).color!;
      final upcomingColor = tester.widget<Material>(upcoming).color!;
      for (final tile in [done, upcoming]) {
        final shape = tester.widget<Material>(tile).shape;
        expect(shape, isA<RoundedRectangleBorder>());
        final border = shape! as RoundedRectangleBorder;
        expect(border.side.color, scheme.onSurface);
        expect(border.side.width, 1);
      }
      expect(
        doneColor,
        darkMode
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerHighest,
      );
      expect(
        upcomingColor,
        darkMode ? scheme.surfaceContainerHighest : scheme.surface,
      );
      expect(
        doneColor.computeLuminance(),
        lessThan(upcomingColor.computeLuminance()),
      );
      expect(tester.takeException(), isNull);
      await planner.flush();
    });
  }

  testWidgets('month fades only boundary days outside selected month', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PlannerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();

    var anchor = DateTime.now();
    var days = monthCalendarDays(anchor);
    if (days.first.month == anchor.month) {
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      anchor = DateTime(anchor.year, anchor.month + 1);
      days = monthCalendarDays(anchor);
    }

    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.childrenDelegate.estimatedChildCount, days.length);

    Finder labelFor(DateTime day) => find.byKey(
      ValueKey('planner-day-label-${day.year}-${day.month}-${day.day}'),
    );
    final outsideLabel = labelFor(days.first);
    final insideLabel = labelFor(DateTime(anchor.year, anchor.month));
    expect(outsideLabel, findsOneWidget);
    expect(insideLabel, findsOneWidget);
    expect(
      tester.widget<Opacity>(
        find.ancestor(of: outsideLabel, matching: find.byType(Opacity)).first,
      ).opacity,
      0.5,
    );
    expect(
      tester.widget<Opacity>(
        find.ancestor(of: insideLabel, matching: find.byType(Opacity)).first,
      ).opacity,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar buttons match sidebar styling and bottom spacing', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: PlannerScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final smart = find.byKey(const ValueKey('planner-smart-session'));
    final create = find.byKey(const ValueKey('planner-new-session'));
    final shape = tester
        .widget<OutlinedButton>(smart)
        .style!
        .shape!
        .resolve(<WidgetState>{});
    final filledShape = tester
        .widget<FilledButton>(create)
        .style!
        .shape!
        .resolve(<WidgetState>{});
    expect(
      (shape! as RoundedRectangleBorder).borderRadius,
      const BorderRadius.all(Radius.circular(12)),
    );
    expect(
      (filledShape! as RoundedRectangleBorder).borderRadius,
      const BorderRadius.all(Radius.circular(12)),
    );
    expect(tester.getSize(smart).width, closeTo(148, 0.1));
    expect(tester.getSize(create).width, closeTo(148, 0.1));
    expect(
      tester.getSize(smart).height,
      StudyActionStyles.sessionButtonHeight,
    );
    expect(
      tester.getSize(create).height,
      StudyActionStyles.sessionButtonHeight,
    );
    expect(tester.getSize(smart).height, 32);
    expect(tester.getSize(create).height, 32);
    expect(
      find.descendant(
        of: smart,
        matching: find.byIcon(Icons.auto_awesome_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: create, matching: find.byIcon(Icons.add_rounded)),
      findsOneWidget,
    );
    final smartContent = find.byKey(
      const ValueKey('planner-smart-session-content'),
    );
    final newContent = find.byKey(
      const ValueKey('planner-new-session-content'),
    );
    expect(
      tester.getCenter(smartContent).dx,
      closeTo(tester.getCenter(smart).dx, 1),
    );
    expect(
      tester.getCenter(newContent).dx,
      closeTo(tester.getCenter(create).dx, 1),
    );
    final calendarMode = find.byType(SegmentedButton<CalendarMode>);
    final calendarTheme = Theme.of(tester.element(calendarMode));
    final modeShape = calendarTheme.segmentedButtonTheme.style!.shape!
        .resolve(<WidgetState>{});
    expect(
      (modeShape! as RoundedRectangleBorder).borderRadius,
      const BorderRadius.all(Radius.circular(12)),
    );
    expect(find.textContaining('Long-press'), findsNothing);
    expect(find.textContaining('Tap any session'), findsNothing);
    final bottomGap = find.byKey(const ValueKey('planner-calendar-bottom-gap'));
    expect(tester.getSize(bottomGap).height, 24);
    expect(
      tester.getBottomLeft(bottomGap).dy,
      closeTo(tester.getBottomLeft(find.byType(PlannerScreen)).dy, 1),
    );
    expect(find.byTooltip('Settings'), findsNothing);
    expect(find.byTooltip('Study history'), findsNothing);

    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    expect(tester.getSize(smart).width, closeTo(179, 1));
    expect(tester.getSize(create).width, closeTo(179, 1));
    expect(tester.getRect(smart).top, closeTo(tester.getRect(create).top, 1));
    expect(tester.takeException(), isNull);
  });
}
