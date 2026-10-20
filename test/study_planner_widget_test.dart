import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/core/widgets/app_header_divider.dart';
import 'package:program/features/editor/state/ink_color_presets.dart';
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

  for (final darkMode in [false, true]) {
    testWidgets('week and month headers share inset segmented bar, '
        'dark=$darkMode', (tester) async {
      final planner = await loadPlanner();
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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

      final grid = find.byKey(const ValueKey('planner-week-time-grid'));
      final weekHeader = find.byKey(
        const ValueKey('planner-week-header-strip'),
      );
      expect(weekHeader, findsOneWidget);
      expect(tester.getRect(grid).left, closeTo(18, 0.1));
      expect(tester.getRect(grid).right, closeTo(1422, 0.1));
      expect(
        tester.getRect(weekHeader).left - tester.getRect(grid).left,
        closeTo(52, 0.1),
      );

      void verifyStrip(Finder finder) {
        final container = tester.widget<Container>(
          find.descendant(
            of: finder,
            matching: find.byType(Container),
          ).first,
        );
        final decoration = container.decoration! as BoxDecoration;
        expect(
          decoration.borderRadius,
          const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
          ),
        );
        expect(container.clipBehavior, Clip.antiAlias);
        final rowFinder = find.descendant(
          of: finder,
          matching: find.byType(Row),
        );
        final row = tester.widget<Row>(rowFinder.first);
        expect(row.children.length, 7);
        for (var index = 0; index < 7; index++) {
          final segment = (row.children[index] as Expanded).child
              as Container;
          final overlay = segment.foregroundDecoration;
          if (index == 6) {
            expect(overlay, isNull);
          } else {
            expect(overlay, isA<BoxDecoration>());
            expect(
              (overlay! as BoxDecoration).border!.right.width,
              1,
            );
          }
        }
      }

      verifyStrip(weekHeader);
      final now = DateTime.now();
      final dayKey = '${now.year}-${now.month}-${now.day}';
      final label = find.byKey(
        ValueKey('planner-week-hour-label-${now.hour}'),
      );
      final hourCell = find.byKey(
        ValueKey('planner-week-cell-$dayKey-${now.hour}'),
      );
      expect(label, findsOneWidget);
      expect(hourCell, findsOneWidget);
      expect(
        tester.getRect(label).top,
        closeTo(tester.getRect(hourCell).top, 2),
      );
      final hourlyList = find.byKey(
        const ValueKey('planner-week-hours'),
      );
      expect(
        tester.getRect(weekHeader).bottom,
        closeTo(tester.getRect(hourlyList).top, 0.1),
      );
      final connector = find.byKey(
        ValueKey('planner-week-hour-connector-${now.hour}'),
      );
      expect(connector, findsOneWidget);
      expect(
        tester.getRect(connector).right,
        closeTo(tester.getRect(hourCell).left, 0.1),
      );
      expect(
        tester.getRect(connector).left,
        greaterThan(tester.getRect(label).right),
      );
      final columnLines = find.byKey(
        const ValueKey('planner-week-column-lines'),
      );
      expect(columnLines, findsOneWidget);
      final painter = tester.widget<CustomPaint>(columnLines);
      expect(painter.foregroundPainter, isNotNull);
      expect(
        tester.getRect(columnLines),
        tester.getRect(hourlyList),
      );

      await tester.tap(find.text('Today').last);
      await tester.pumpAndSettle();
      final row = find.byKey(
        ValueKey('planner-hour-row-$dayKey-${now.hour}'),
      );
      final hourText = find.descendant(
        of: row,
        matching: find.text(
          '${now.hour.toString().padLeft(2, '0')}:00',
        ),
      );
      expect(hourText, findsOneWidget);
      expect(
        tester.getRect(hourText).top,
        closeTo(tester.getRect(row).top, 2),
      );

      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();
      final monthHeader = find.byKey(
        const ValueKey('planner-month-header-strip'),
      );
      expect(monthHeader, findsOneWidget);
      expect(tester.getRect(monthHeader).left, closeTo(18, 0.1));
      expect(tester.getRect(monthHeader).right, closeTo(1422, 0.1));
      verifyStrip(monthHeader);
      final monthGrid = find.byKey(
        const ValueKey('planner-month-grid-surface'),
      );
      expect(monthGrid, findsOneWidget);
      expect(
        tester.getRect(monthHeader).bottom,
        closeTo(tester.getRect(monthGrid).top, 0.1),
      );
      final gridSurface = tester.widget<Container>(monthGrid);
      final decoration = gridSurface.decoration! as BoxDecoration;
      expect(
        decoration.borderRadius,
        const BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      );
      expect(gridSurface.clipBehavior, Clip.antiAlias);
      final start = monthCalendarDays(DateTime(now.year, now.month));
      final first = start.first;
      final seventh = start[6];

      Finder monthCell(DateTime day) => find.byKey(
        ValueKey(
          'planner-day-cell-${day.year}-${day.month}-${day.day}',
        ),
      );

      final firstCell = tester.widget<Container>(monthCell(first));
      final lastColumn = tester.widget<Container>(monthCell(seventh));
      expect(firstCell.margin, EdgeInsets.zero);
      expect(lastColumn.margin, EdgeInsets.zero);
      final firstBorder = firstCell.decoration! as BoxDecoration;
      final seventhBorder = lastColumn.decoration! as BoxDecoration;
      expect(firstBorder.borderRadius, isNull);
      expect(seventhBorder.borderRadius, isNull);
      expect(firstBorder.border!.right.width, 1);
      expect(firstBorder.border!.bottom.width, 1);
      final adjacentDay = start[1];
      final secondRowDay = start[7];
      expect(
        tester.getRect(monthCell(first)).right,
        closeTo(tester.getRect(monthCell(adjacentDay)).left, 0.1),
      );
      expect(
        tester.getRect(monthCell(first)).bottom,
        closeTo(tester.getRect(monthCell(secondRowDay)).top, 0.1),
      );
      expect(seventhBorder.border!.right, BorderSide.none);
      expect(seventhBorder.border!.bottom.width, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final darkMode in [false, true]) {
    testWidgets('out-of-month cells use lighter background, dark=$darkMode', (
      tester,
    ) async {
      final planner = await loadPlanner();
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();

      var month = DateTime.now();
      var days = monthCalendarDays(month);
      if (days.every((date) => date.month == month.month)) {
        await tester.tap(find.byTooltip('Next'));
        await tester.pumpAndSettle();
        month = DateTime(month.year, month.month + 1);
        days = monthCalendarDays(month);
      }
      final other = days.firstWhere(
        (date) => date.month != month.month,
      );
      final inside = days.firstWhere(
        (date) => date.month == month.month &&
            !DateUtils.isSameDay(date, DateTime.now()),
      );
      Finder dayCell(DateTime date) => find.byKey(
        ValueKey(
          'planner-day-cell-${date.year}-${date.month}-${date.day}',
        ),
      );

      final outerCell = tester.widget<Container>(dayCell(other));
      final innerCell = tester.widget<Container>(dayCell(inside));
      final theme = Theme.of(tester.element(dayCell(other)));
      final outerColor = (outerCell.decoration! as BoxDecoration).color!;
      final innerColor = (innerCell.decoration! as BoxDecoration).color!;
      expect(outerColor, plannerOutsideMonthSurface(theme));
      expect(
        outerColor.computeLuminance(),
        greaterThan(innerColor.computeLuminance()),
      );
      expect(
        (outerCell.decoration! as BoxDecoration).border!.right,
        (innerCell.decoration! as BoxDecoration).border!.right,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('calendar hides vertical scrollbar without blocking touch', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          home: const PlannerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final config = find.byKey(const ValueKey('planner-scrollbar-free'));
    expect(config, findsOneWidget);
    expect(
      find.descendant(
        of: config,
        matching: find.byType(RawScrollbar),
      ),
      findsNothing,
    );

    final hours = find.byKey(const ValueKey('planner-week-hours'));
    final scrollable = find.descendant(
      of: hours,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final firstOffset = position.pixels;
    await tester.drag(hours, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(firstOffset));

    await tester.tap(find.text('Today').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('planner-scrollbar-free')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: config,
        matching: find.byType(RawScrollbar),
      ),
      findsNothing,
    );
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('planner-scrollbar-free')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: config,
        matching: find.byType(RawScrollbar),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow week keeps side padding while hours scroll', (
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
    final week = find.byKey(const ValueKey('planner-week-time-grid'));
    expect(tester.getRect(week).left, closeTo(18, 0.1));
    final header = find.byKey(
      const ValueKey('planner-week-header-strip'),
    );
    expect(tester.getRect(header).left, closeTo(70, 0.1));
    expect(
      tester.getRect(header).bottom,
      closeTo(
        tester.getRect(
          find.byKey(const ValueKey('planner-week-hours')),
        ).top,
        0.1,
      ),
    );
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    final unifiedList = find.byKey(
      const ValueKey('planner-mobile-month-surface'),
    );
    expect(unifiedList, findsOneWidget);
    expect(
      tester.widget<Container>(unifiedList).clipBehavior,
      Clip.antiAlias,
    );
    expect(tester.takeException(), isNull);
  });

  for (final darkMode in [false, true]) {
    testWidgets('today normal; week and month lightly shaded, dark=$darkMode', (
      tester,
    ) async {
      final planner = await loadPlanner();
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now();
      final other = DateTime(
        now.year,
        now.month,
        now.day + (now.weekday == DateTime.sunday ? -1 : 1),
      );
      final session = planner.create(
        title: 'Timed lesson',
        scheduledAt: DateTime(now.year, now.month, now.day, now.hour),
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

      String keyDate(DateTime date) =>
          '${date.year}-${date.month}-${date.day}';
      final todayKey = keyDate(now);
      final cell = find.byKey(ValueKey('planner-day-cell-$todayKey'));
      final otherCell = find.byKey(
        ValueKey('planner-day-cell-${keyDate(other)}'),
      );
      final theme = Theme.of(tester.element(cell));
      Color cellColor(Finder finder) =>
          (tester.widget<Container>(finder).decoration! as BoxDecoration)
              .color!;
      final base = theme.colorScheme.surfaceContainerLowest;
      final shade = darkMode
          ? theme.colorScheme.surface
          : theme.colorScheme.surfaceContainerHighest;
      final expected = Color.alphaBlend(
        shade.withValues(alpha: 0.5),
        base,
      );
      expect(cellColor(cell), expected);
      expect(cellColor(otherCell), base);
      expect(
        cellColor(cell).computeLuminance(),
        lessThan(cellColor(otherCell).computeLuminance()),
      );

      final week = find.byKey(const ValueKey('planner-week-time-grid'));
      expect(week, findsOneWidget);
      expect(find.byKey(const ValueKey('planner-week-hours')), findsOneWidget);
      expect(
        tester.widget<ListView>(
          find.byKey(const ValueKey('planner-week-hours')),
        ).childrenDelegate.estimatedChildCount,
        24,
      );
      expect(
        find.byKey(ValueKey('planner-week-hour-label-${now.hour}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('planner-week-now-line-$todayKey')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('planner-week-cell-$todayKey-${now.hour}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('planner-hour-list-$todayKey')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey('planner-session-tile:${session.id}')),
        findsOneWidget,
      );

      await tester.tap(find.text('Today').last);
      await tester.pumpAndSettle();
      expect(cellColor(cell), base);
      final grid = find.byKey(ValueKey('planner-hour-list-$todayKey'));
      expect(grid, findsOneWidget);
      expect(
        find.byKey(ValueKey('planner-now-line-$todayKey')),
        findsOneWidget,
      );
      final hour = find.byKey(
        ValueKey('planner-hour-row-$todayKey-${now.hour}'),
      );
      final time = find.descendant(
        of: hour,
        matching: find.text(
          '${now.hour.toString().padLeft(2, '0')}:00',
        ),
      );
      final tile = find.byKey(ValueKey('planner-session-tile:${session.id}'));
      expect(
        tester.getRect(tile).left - tester.getRect(time).right,
        greaterThan(22),
      );

      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();
      expect(cellColor(cell), expected);
      expect(find.byKey(ValueKey('planner-now-line-$todayKey')), findsNothing);
      expect(find.byKey(const ValueKey('planner-week-hours')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('phone planner uses shared week axis and compact actions', (
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

    expect(
      find.byKey(const ValueKey('planner-week-time-grid')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mobile-planner-days')), findsNothing);
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

      if (now.weekday == DateTime.sunday) {
        await tester.tap(find.byTooltip('Next'));
        await tester.pumpAndSettle();
      }

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

  testWidgets('upcoming scrolls independently beyond half of folder area', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(600, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final sessions = [
      for (var i = 0; i < 14; i++)
        planner.create(
          title: 'Upcoming $i',
          scheduledAt: tomorrow.add(Duration(hours: i)),
        ),
    ];
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: StudyTimerCard(upcomingMaxHeight: 140),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final region = find.byKey(
      const ValueKey('sidebar-upcoming-height-cap'),
    );
    expect(tester.getSize(region).height, lessThanOrEqualTo(140));
    final scroll = find.byKey(const ValueKey('sidebar-upcoming-scroll'));
    expect(scroll, findsOneWidget);
    expect(planner.upcoming.length, 14);
    expect(
      find.byKey(ValueKey('sidebar-upcoming-card:${sessions.first.id}')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(ValueKey('sidebar-upcoming-card:${sessions.last.id}')),
      120,
      scrollable: find.descendant(
        of: scroll,
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      find.byKey(ValueKey('sidebar-upcoming-card:${sessions.last.id}')),
      findsOneWidget,
    );
    expect(tester.getSize(region).height, lessThanOrEqualTo(140));
    expect(tester.takeException(), isNull);
  });

  testWidgets('running sidebar hides start actions but keeps upcoming', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final running = planner.create(
      title: 'Active focus',
      scheduledAt: DateTime.now(),
    );
    final later = planner.create(
      title: 'Next lesson',
      scheduledAt: DateTime.now().add(const Duration(days: 1)),
    );
    planner.start(running.id);
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: Scaffold(body: StudyTimerCard())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sidebar-start-session')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-smart-session')), findsNothing);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(
      find.byKey(ValueKey('sidebar-upcoming-card:${later.id}')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('sidebar-timer-stop')));
    await tester.pumpAndSettle();
    final heading = find.byKey(const ValueKey('study-finished-title'));
    expect(heading, findsOneWidget);
    expect(
      tester.widget<Text>(heading).style,
      AppHeaderDivider.titleStyle,
    );
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('Skip rating'));
    await tester.pumpAndSettle();
  });

  testWidgets('calendar new and edit forms persist chosen colour', (
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

    await tester.tap(find.byKey(const ValueKey('planner-new-session')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('study-session-colour')), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'Coloured session',
    );
    await tester.tap(find.byKey(const ValueKey('study-session-colour')));
    await tester.pumpAndSettle();
    final first = InkColorPreset.blue.colors.first;
    final swatch = find.byKey(
      ValueKey('color-picker-palette-blue-${first.toARGB32()}'),
    );
    expect(swatch, findsOneWidget);
    await tester.tap(swatch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final item = planner.sessions.single;
    expect(item.colorValue, first.toARGB32());
    final calendar = find.byKey(
      ValueKey('planner-session-tile:${item.id}'),
    );
    final theme = Theme.of(tester.element(calendar));
    expect(
      tester.widget<Material>(calendar).color,
      StudyActionStyles.sessionCardColor(theme, first.toARGB32()),
    );

    await tester.tap(calendar);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('study-session-colour-reset')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('study-session-colour-reset')));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(item.colorValue, isNull);
    await planner.flush();
  });

  testWidgets('smart session lets user set focus block count', (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('planner-smart-session')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('study-focus-blocks')), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'Two blocks',
    );
    await tester.tap(find.byKey(const ValueKey('study-focus-blocks')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save & start'));
    await tester.pumpAndSettle();
    expect(planner.active?.focusBlocks, 2);
    expect(planner.active?.technique, StudyTechnique.pomodoro);
    await planner.flush();
  });

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

    final toggle = find.byKey(const ValueKey('sidebar-timer-toggle'));
    final stop = find.byKey(const ValueKey('sidebar-timer-stop'));
    expect(
      tester.getSize(toggle).height,
      StudyActionStyles.sessionButtonHeight,
    );
    expect(tester.getSize(stop).height, StudyActionStyles.sessionButtonHeight);
    final shape = tester.widget<OutlinedButton>(toggle).style!.shape!
        .resolve(<WidgetState>{});
    final stopShape = tester.widget<OutlinedButton>(stop).style!.shape!
        .resolve(<WidgetState>{});
    expect(shape, StudyActionStyles.sessionButtonShape);
    expect(stopShape, StudyActionStyles.sessionButtonShape);

    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(planner.active?.status, StudyStatus.paused);
    await tester.tap(find.byTooltip('Stop session'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('study-finished-title')), findsOneWidget);
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
    expect(find.byKey(const ValueKey('study-finished-title')), findsOneWidget);

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
    expect(find.byKey(const ValueKey('study-finished-title')), findsNothing);
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
