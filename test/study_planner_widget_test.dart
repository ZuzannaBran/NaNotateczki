import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/core/theme/app_colors.dart';
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

  Future<void> openCalendarEntry(
    WidgetTester tester,
    StudyEntryKind kind,
  ) async {
    await tester.tap(find.text('Day').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Plan on this day').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey(
          kind == StudyEntryKind.event
              ? 'calendar-add-event'
              : 'calendar-add-session',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('calendar and upcoming cards invert user colors in dark mode', () {
    const selected = Color(0xFFACBED8);
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final darkMode = theme.brightness == Brightness.dark;
      final base = StudyActionStyles.plannedSessionColor(theme);
      final display = AppColors.displayInkColor(selected, darkMode: darkMode);
      final expected = Color.alphaBlend(
        display.withValues(alpha: darkMode ? 0.45 : 0.32),
        base,
      );
      expect(
        StudyActionStyles.sessionCardColor(theme, selected.toARGB32()),
        expected,
      );
      expect(StudyActionStyles.sessionCardColor(theme, null), base);
    }
    expect(
      StudyActionStyles.sessionCardColor(AppTheme.light(), selected.toARGB32()),
      isNot(
        StudyActionStyles.sessionCardColor(
          AppTheme.dark(),
          selected.toARGB32(),
        ),
      ),
    );
  });

  for (final darkMode in [false, true]) {
    testWidgets('calendar color preview follows theme, dark=$darkMode', (
      tester,
    ) async {
      final planner = await loadPlanner();
      final color = InkColorPreset.pink.colors[1];
      final event = planner.create(
        kind: StudyEntryKind.event,
        title: 'Colored event',
        scheduledAt: DateTime.now(),
        colorValue: color.toARGB32(),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<StudyPlannerController>.value(
          value: planner,
          child: MaterialApp(
            theme: darkMode ? AppTheme.dark() : AppTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showStudySessionEditor(context, session: event),
                  child: const Text('Edit event color'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit event color'));
      await tester.pumpAndSettle();
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('study-session-colour')),
          matching: find.byIcon(Icons.palette_outlined),
        ),
      );
      expect(icon.color, AppColors.displayInkColor(color, darkMode: darkMode));
      expect(planner.sessions.single.colorValue, color.toARGB32());
    });
  }

  testWidgets('upcoming shows only sessions with a light beige outline', (
    tester,
  ) async {
    final planner = await loadPlanner();
    final date = DateTime.now().add(const Duration(days: 1));
    final event = planner.create(
      kind: StudyEntryKind.event,
      title: 'Museum visit',
      scheduledAt: date,
    );
    final session = planner.create(title: 'Revision', scheduledAt: date);
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: Scaffold(body: StudyTimerCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(planner.upcoming, hasLength(1));
    expect(find.text('Museum visit'), findsNothing);
    expect(find.text('Revision'), findsOneWidget);
    expect(find.byTooltip('Edit event'), findsNothing);
    expect(planner.start(event.id), isFalse);

    final card = tester.widget<Material>(
      find.byKey(ValueKey('sidebar-upcoming-card:${session.id}')),
    );
    expect(
      (card.shape! as RoundedRectangleBorder).side.color,
      AppColors.toolbar,
    );
    final panel = tester.widget<Padding>(
      find.byKey(const ValueKey('study-timer-card')),
    );
    expect(panel.padding, const EdgeInsets.fromLTRB(14, 20, 14, 0));
    await planner.flush();
  });

  testWidgets('timer has bottom gap only without upcoming sessions', (
    tester,
  ) async {
    final planner = await loadPlanner();
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: Scaffold(body: StudyTimerCard())),
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('study-timer-card'));
    expect(
      tester.widget<Padding>(panel).padding,
      const EdgeInsets.fromLTRB(14, 20, 14, 16),
    );
    final start = find.byKey(const ValueKey('sidebar-start-session'));
    expect(
      tester.getRect(panel).bottom - tester.getRect(start).bottom,
      closeTo(16, 0.1),
    );

    final planned = planner.create(
      title: 'Upcoming check',
      scheduledAt: DateTime.now().add(const Duration(days: 1)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Padding>(panel).padding,
      const EdgeInsets.fromLTRB(14, 20, 14, 0),
    );
    final card = find.byKey(ValueKey('sidebar-upcoming-card:${planned.id}'));
    expect(card, findsOneWidget);
    expect(
      tester.getRect(panel).bottom - tester.getRect(card).bottom,
      closeTo(0, 0.1),
    );
  });

  for (final kind in StudyEntryKind.values) {
    testWidgets('name and description stay fixed while editing $kind', (
      tester,
    ) async {
      final planner = await loadPlanner();
      await tester.binding.setSurfaceSize(const Size(1440, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<StudyPlannerController>.value(
          value: planner,
          child: const MaterialApp(home: PlannerScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await openCalendarEntry(tester, kind);

      final nameLabel = find.byKey(const ValueKey('study-entry-name-label'));
      final descriptionLabel = find.byKey(
        const ValueKey('study-entry-description-label'),
      );
      final nameField = find.byKey(const ValueKey('study-entry-name-field'));
      final descriptionField = find.byKey(
        const ValueKey('study-entry-description-field'),
      );
      final nameLocation = tester.getTopLeft(nameLabel);
      final descriptionLocation = tester.getTopLeft(descriptionLabel);
      final nameStyle = tester.widget<Text>(nameLabel).style;
      final descriptionStyle = tester.widget<Text>(descriptionLabel).style;
      expect(nameStyle?.fontSize, descriptionStyle?.fontSize);
      for (final field in [nameField, descriptionField]) {
        final input = tester.widget<TextField>(field);
        expect(input.decoration?.labelText, isNull);
        expect(
          input.decoration?.floatingLabelBehavior,
          FloatingLabelBehavior.never,
        );
      }
      await tester.enterText(nameField, 'Planning');
      await tester.pumpAndSettle();
      await tester.enterText(descriptionField, 'Fixed text');
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nameLabel), nameLocation);
      expect(tester.getTopLeft(descriptionLabel), descriptionLocation);
      expect(
        tester.widget<Text>(nameLabel).style?.fontSize,
        nameStyle?.fontSize,
      );
      expect(
        tester.widget<Text>(descriptionLabel).style?.fontSize,
        descriptionStyle?.fontSize,
      );
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new calendar event is editable and never starts a timer', (
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
    await openCalendarEntry(tester, StudyEntryKind.event);
    expect(find.text('New event'), findsOneWidget);
    expect(find.text('Study technique'), findsNothing);
    expect(find.byKey(const ValueKey('event-all-day')), findsOneWidget);
    expect(find.byKey(const ValueKey('event-end-date')), findsOneWidget);
    expect(find.byKey(const ValueKey('event-repeat')), findsOneWidget);
    expect(find.text('Focus blocks'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'Lecture');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(planner.sessions.single.kind, StudyEntryKind.event);
    expect(planner.active, isNull);
    expect(planner.start(planner.sessions.single.id), isFalse);
    await planner.flush();
  });

  testWidgets('calendar plus asks for event or study session', (tester) async {
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
    await tester.tap(find.text('Day').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Plan on this day').first);
    await tester.pumpAndSettle();
    expect(find.text('Add to calendar'), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-add-event')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-add-session')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('calendar-add-event')));
    await tester.pumpAndSettle();
    expect(find.text('New event'), findsOneWidget);
    expect(find.text('Study technique'), findsNothing);
    final allDayTile = find.byKey(const ValueKey('event-all-day'));
    final checkbox = find.descendant(
      of: allDayTile,
      matching: find.byType(Checkbox),
    );
    expect(checkbox, findsOneWidget);
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);
    await tester.tap(allDayTile);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);
    expect(find.text('Duration (minutes)'), findsNothing);
    expect(find.byKey(const ValueKey('event-repeat')), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'All-day meeting');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(planner.sessions.single.allDay, isTrue);
    expect(planner.sessions.single.kind, StudyEntryKind.event);
    expect(planner.active, isNull);
  });

  test('all-day calendar blocks do not shift at daylight saving time', () {
    final event = StudySession(
      id: 'dst',
      kind: StudyEntryKind.event,
      title: 'Holiday',
      scheduledAt: DateTime(2026, 10, 25),
      minutes: 1440,
      allDay: true,
    );
    expect(event.scheduledDurationMinutes, 1440);
    expect(
      calendarTimeSpan(event, DateTime(2026, 10, 25))!.height,
      closeTo(24 * 64, 0.001),
    );
    expect(calendarTimeSpan(event, DateTime(2026, 10, 26)), isNull);
  });

  test('scheduled session spans the correct minutes including breaks', () {
    final day = DateTime(2026, 10, 20);
    final halfHour = StudySession(
      id: 'half',
      title: 'Half hour',
      scheduledAt: DateTime(2026, 10, 20, 15, 45),
      minutes: 30,
    );
    final span = calendarTimeSpan(halfHour, day)!;
    expect(span.top, closeTo(15.75 * 64, 0.001));
    expect(span.height, closeTo(32, 0.001));
    expect(span.top + span.height, closeTo(16.25 * 64, 0.001));

    final smart = StudySession(
      id: 'smart',
      title: 'Pomodoro',
      scheduledAt: DateTime(2026, 10, 20, 12, 30),
      minutes: 30,
      technique: StudyTechnique.pomodoro,
      focusBlocks: 3,
    );
    expect(smart.scheduledDurationMinutes, 85);
    expect(calendarTimeSpan(smart, day)!.height, closeTo(85 * 64 / 60, 0.001));
    final midnight = StudySession(
      id: 'next',
      title: 'Late session',
      scheduledAt: DateTime(2026, 10, 20, 23, 45),
      minutes: 30,
    );
    expect(calendarTimeSpan(midnight, day)!.height, closeTo(16, 0.001));
    final nextDay = calendarTimeSpan(midnight, DateTime(2026, 10, 21))!;
    expect(nextDay.top, 0);
    expect(nextDay.height, closeTo(16, 0.001));
  });

  testWidgets('minute-precise geometry agrees in Week and Day', (tester) async {
    final planner = await loadPlanner();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final session = planner.create(
      title: 'Quarter past',
      scheduledAt: DateTime(day.year, day.month, day.day, 15, 45),
      minutes: 30,
    );
    final key = '${day.year}-${day.month}-${day.day}';
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(home: PlannerScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final weekly = find.byKey(
      ValueKey('planner-time-position:${session.id}-$key'),
    );
    final week15 = find.byKey(ValueKey('planner-week-cell-$key-15'));
    final week16 = find.byKey(ValueKey('planner-week-cell-$key-16'));
    expect(weekly, findsOneWidget);
    expect(
      tester.getRect(weekly).top - tester.getRect(week15).top,
      closeTo(48, 0.1),
    );
    expect(
      tester.getRect(weekly).bottom - tester.getRect(week16).top,
      closeTo(16, 0.1),
    );
    await tester.tap(find.text('Day').last);
    await tester.pumpAndSettle();
    final daily = find.byKey(ValueKey('planner-time-position:${session.id}'));
    final day15 = find.byKey(ValueKey('planner-hour-row-$key-15'));
    final day16 = find.byKey(ValueKey('planner-hour-row-$key-16'));
    expect(daily, findsOneWidget);
    expect(
      tester.getRect(daily).top - tester.getRect(day15).top,
      closeTo(48, 0.1),
    );
    expect(
      tester.getRect(daily).bottom - tester.getRect(day16).top,
      closeTo(16, 0.1),
    );
    expect(tester.takeException(), isNull);
    await planner.flush();
  });

  testWidgets('week and month cells open selected Day', (tester) async {
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
    final today = DateUtils.dateOnly(DateTime.now());
    final mon = DateTime(
      today.year,
      today.month,
      today.day - today.weekday + 1,
    );
    final tue = DateTime(mon.year, mon.month, mon.day + 1);
    String key(DateTime date) => '${date.year}-${date.month}-${date.day}';
    await tester.tap(find.byKey(ValueKey('planner-day-label-${key(tue)}')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('planner-hour-list-${key(tue)}')),
      findsOneWidget,
    );
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    final target = DateTime(tue.year, tue.month, 12);
    final targetLabel = find.byKey(
      ValueKey('planner-day-label-${key(target)}'),
    );
    await tester.ensureVisible(targetLabel);
    await tester.tap(targetLabel);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('planner-hour-list-${key(target)}')),
      findsOneWidget,
    );
    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('planner-hour-list-${key(today)}')),
      findsOneWidget,
    );
    await planner.flush();
  });

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
    expect(find.text('Calendar'), findsOneWidget);
    expect(find.textContaining('Calculus'), findsWidgets);

    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^Mon \d+$')), findsWidgets);
    await tester.tap(find.text('Day').last);
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
      final bottomCorners = tester.widget<ClipRRect>(
        find.byKey(const ValueKey('planner-week-bottom-corners')),
      );
      expect(
        bottomCorners.borderRadius,
        const BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      );

      void verifyStrip(Finder finder) {
        final container = tester.widget<Container>(
          find.descendant(of: finder, matching: find.byType(Container)).first,
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
          final segment = (row.children[index] as Expanded).child as Container;
          final overlay = segment.foregroundDecoration;
          if (index == 6) {
            expect(overlay, isNull);
          } else {
            expect(overlay, isA<BoxDecoration>());
            final overlayBorder = (overlay! as BoxDecoration).border! as Border;
            expect(overlayBorder.right.width, 1);
          }
        }
      }

      verifyStrip(weekHeader);
      final now = DateTime.now();
      final dayKey = '${now.year}-${now.month}-${now.day}';
      final label = find.byKey(ValueKey('planner-week-hour-label-${now.hour}'));
      final hourCell = find.byKey(
        ValueKey('planner-week-cell-$dayKey-${now.hour}'),
      );
      expect(label, findsOneWidget);
      expect(hourCell, findsOneWidget);
      expect(
        tester.getRect(label).top,
        closeTo(tester.getRect(hourCell).top, 2),
      );
      final hourlyList = find.byKey(const ValueKey('planner-week-hours'));
      expect(
        tester.getRect(weekHeader).bottom,
        closeTo(tester.getRect(hourlyList).top, 0.1),
      );
      final connector = find.byKey(
        ValueKey('planner-week-hour-connector-${now.hour}'),
      );
      expect(connector, findsNothing);
      final columnLines = find.byKey(
        const ValueKey('planner-week-column-lines'),
      );
      expect(columnLines, findsOneWidget);
      final painter = tester.widget<CustomPaint>(columnLines);
      expect(painter.painter, isNotNull);
      expect(tester.getRect(columnLines), tester.getRect(hourlyList));

      await tester.tap(find.text('Day').last);
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('planner-hour-row-$dayKey-${now.hour}'));
      final hourText = find.descendant(
        of: row,
        matching: find.text('${now.hour.toString().padLeft(2, '0')}:00'),
      );
      expect(hourText, findsOneWidget);
      expect(
        tester.getCenter(hourText).dy,
        closeTo(tester.getCenter(row).dy, 2),
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
        ValueKey('planner-day-cell-${day.year}-${day.month}-${day.day}'),
      );

      final firstCell = tester.widget<Container>(monthCell(first));
      final lastColumn = tester.widget<Container>(monthCell(seventh));
      expect(firstCell.margin, EdgeInsets.zero);
      expect(lastColumn.margin, EdgeInsets.zero);
      final firstDecoration = firstCell.decoration! as BoxDecoration;
      final seventhDecoration = lastColumn.decoration! as BoxDecoration;
      final firstBorder = firstDecoration.border! as Border;
      final seventhBorder = seventhDecoration.border! as Border;
      expect(firstDecoration.borderRadius, isNull);
      expect(seventhDecoration.borderRadius, isNull);
      expect(firstBorder.right.width, 1);
      expect(firstBorder.bottom.width, 1);
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
      expect(seventhBorder.right, BorderSide.none);
      expect(seventhBorder.bottom.width, 1);
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
      final other = days.firstWhere((date) => date.month != month.month);
      final inside = days.firstWhere(
        (date) =>
            date.month == month.month &&
            !DateUtils.isSameDay(date, DateTime.now()),
      );
      Finder dayCell(DateTime date) => find.byKey(
        ValueKey('planner-day-cell-${date.year}-${date.month}-${date.day}'),
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
      final outerBorder =
          (outerCell.decoration! as BoxDecoration).border! as Border;
      final innerBorder =
          (innerCell.decoration! as BoxDecoration).border! as Border;
      expect(outerBorder.right, innerBorder.right);
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
      find.descendant(of: config, matching: find.byType(RawScrollbar)),
      findsNothing,
    );

    final hours = find.byKey(const ValueKey('planner-week-hours'));
    final scrollable = find.descendant(
      of: hours,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    final firstOffset = position.pixels;
    await tester.drag(hours, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(firstOffset));

    await tester.tap(find.text('Day').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('planner-scrollbar-free')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: config, matching: find.byType(RawScrollbar)),
      findsNothing,
    );
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('planner-scrollbar-free')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: config, matching: find.byType(RawScrollbar)),
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
    final header = find.byKey(const ValueKey('planner-week-header-strip'));
    expect(tester.getRect(header).left, closeTo(70, 0.1));
    expect(
      tester.getRect(header).bottom,
      closeTo(
        tester.getRect(find.byKey(const ValueKey('planner-week-hours'))).top,
        0.1,
      ),
    );
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    final unifiedList = find.byKey(
      const ValueKey('planner-mobile-month-surface'),
    );
    expect(unifiedList, findsOneWidget);
    expect(tester.widget<Container>(unifiedList).clipBehavior, Clip.antiAlias);
    expect(tester.takeException(), isNull);
  });

  for (final darkMode in [false, true]) {
    testWidgets(
      'today normal; week and month clearly lighter, dark=$darkMode',
      (tester) async {
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
        Color cellColor(Finder finder) {
          final container = tester.widget<Container>(finder);
          final decoration = container.decoration;
          return decoration is BoxDecoration
              ? decoration.color!
              : container.color!;
        }

        final base = theme.colorScheme.surfaceContainerLowest;
        final expected = darkMode ? AppColors.darkPaper : AppColors.paper;
        expect(cellColor(cell), expected);
        expect(cellColor(otherCell), base);
        expect(
          cellColor(cell).computeLuminance(),
          greaterThan(cellColor(otherCell).computeLuminance()),
        );

        final week = find.byKey(const ValueKey('planner-week-time-grid'));
        expect(week, findsOneWidget);
        expect(
          find.byKey(const ValueKey('planner-week-hours')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ListView>(
                find.byKey(const ValueKey('planner-week-hours')),
              )
              .childrenDelegate
              .estimatedChildCount,
          1,
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

        await tester.tap(find.text('Day').last);
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
          matching: find.text('${now.hour.toString().padLeft(2, '0')}:00'),
        );
        final tile = find.byKey(ValueKey('planner-session-tile:${session.id}'));
        expect(
          tester.getRect(tile).left - tester.getRect(time).right,
          closeTo(0, 0.1),
        );

        await tester.tap(find.text('Month'));
        await tester.pumpAndSettle();
        expect(cellColor(cell), expected);
        expect(
          find.byKey(ValueKey('planner-now-line-$todayKey')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('planner-week-hours')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
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
    expect(find.byKey(const ValueKey('planner-smart-session')), findsNothing);
    expect(find.byKey(const ValueKey('planner-new-session')), findsNothing);
    expect(find.byKey(const ValueKey('planner-new-event')), findsNothing);
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
    await openCalendarEntry(tester, StudyEntryKind.session);
    expect(tester.takeException(), isNull);
    expect(find.text('Name'), findsOneWidget);
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
        tester
            .widget<Padding>(find.byKey(const ValueKey('study-timer-card')))
            .padding,
        const EdgeInsets.fromLTRB(14, 20, 14, 16),
      );
      expect(timer.bottom - start.bottom, closeTo(16, 0.1));
      expect(
        start.top -
            tester
                .getRect(find.text('Ready for your next focus session?'))
                .bottom,
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

      final calendar = find.byKey(ValueKey('planner-session-tile:${first.id}'));
      expect(calendar, findsOneWidget);
      final sidebarMaterial = tester.widget<Material>(upcoming);
      final calendarMaterial = tester.widget<Material>(calendar);
      expect(sidebarMaterial.color, calendarMaterial.color);
      final sidebarShape = sidebarMaterial.shape! as RoundedRectangleBorder;
      expect(sidebarShape.borderRadius, BorderRadius.circular(12));
      expect(
        sidebarShape.side.color,
        darkMode
            ? Theme.of(tester.element(upcoming)).colorScheme.outlineVariant
            : AppColors.toolbar,
      );

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

    final region = find.byKey(const ValueKey('sidebar-upcoming-height-cap'));
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
    expect(tester.widget<Text>(heading).style, AppHeaderDivider.titleStyle);
    expect(tester.widget<Text>(heading).textAlign, TextAlign.center);
    expect(
      find.ancestor(of: heading, matching: find.byType(Center)),
      findsWidgets,
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

    await openCalendarEntry(tester, StudyEntryKind.session);
    expect(find.byKey(const ValueKey('study-session-colour')), findsOneWidget);
    final nameInput = tester.widget<TextField>(
      find.byKey(const ValueKey('study-entry-name-field')),
    );
    final descriptionInput = tester.widget<TextField>(
      find.byKey(const ValueKey('study-entry-description-field')),
    );
    expect(nameInput.decoration!.labelText, isNull);
    expect(descriptionInput.decoration!.labelText, isNull);
    final nameLabel = find.byKey(const ValueKey('study-entry-name-label'));
    final descriptionLabel = find.byKey(
      const ValueKey('study-entry-description-label'),
    );
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    expect(
      tester.getTopLeft(nameLabel).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('study-entry-name-field')))
            .dy,
      ),
    );
    expect(
      tester.getTopLeft(descriptionLabel).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('study-entry-description-field')),
            )
            .dy,
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('study-entry-name-field')),
      'Coloured session',
    );
    await tester.pumpAndSettle();
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('study-session-colour')));
    await tester.pumpAndSettle();
    expect(find.text('Pick color'), findsOneWidget);
    expect(find.text('Palettes'), findsOneWidget);
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
    final calendar = find.byKey(ValueKey('planner-session-tile:${item.id}'));
    final theme = Theme.of(tester.element(calendar));
    expect(
      tester.widget<Material>(calendar).color,
      StudyActionStyles.sessionCardColor(theme, first.toARGB32()),
    );

    final calendarTap = tester.widget<InkWell>(
      find.descendant(of: calendar, matching: find.byType(InkWell)),
    );
    calendarTap.onTap!();
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
        child: const MaterialApp(home: Scaffold(body: StudyTimerCard())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sidebar-smart-session')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('study-focus-blocks')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('study-entry-name-field')),
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
      find.byKey(const ValueKey('study-entry-name-field')),
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
    final shape = tester
        .widget<OutlinedButton>(toggle)
        .style!
        .shape!
        .resolve(<WidgetState>{});
    final stopShape = tester
        .widget<OutlinedButton>(stop)
        .style!
        .shape!
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
    await tester.tap(find.byKey(ValueKey('planner-session-tile:${rated.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Productivity: ★★★☆☆'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('planner-session-tile:${unrated.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Productivity:'), findsNothing);
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
      tester
          .widget<Opacity>(
            find
                .ancestor(of: outsideLabel, matching: find.byType(Opacity))
                .first,
          )
          .opacity,
      0.5,
    );
    expect(
      tester
          .widget<Opacity>(
            find
                .ancestor(of: insideLabel, matching: find.byType(Opacity))
                .first,
          )
          .opacity,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets('calendar header displays only selected period at $width', (
      tester,
    ) async {
      final planner = await loadPlanner();
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<StudyPlannerController>.value(
          value: planner,
          child: const MaterialApp(home: PlannerScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final heading = find.byKey(const ValueKey('planner-period-heading'));
      String currentPeriod() => tester.widget<Text>(heading).data!;

      expect(heading, findsOneWidget);
      expect(find.text('Today'), findsNothing);
      final initialWeek = currentPeriod();
      expect(initialWeek, contains('–'));
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(currentPeriod(), isNot(initialWeek));
      expect(find.text('Today'), findsNothing);

      await tester.tap(find.text('Day').last);
      await tester.pumpAndSettle();
      final day = currentPeriod();
      expect(day, contains(DateTime.now().year.toString()));
      await tester.tap(find.byTooltip('Previous'));
      await tester.pumpAndSettle();
      expect(currentPeriod(), isNot(day));

      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();
      expect(currentPeriod(), contains(DateTime.now().year.toString()));
      expect(find.text('Today'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('calendar has no extra action bar on desktop or phone', (
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
    expect(find.text('Calendar'), findsOneWidget);
    for (final key in [
      'planner-smart-session',
      'planner-new-session',
      'planner-new-event',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
    final mode = find.byType(SegmentedButton<CalendarMode>);
    final theme = Theme.of(tester.element(mode));
    final shape = theme.segmentedButtonTheme.style!.shape!.resolve(
      <WidgetState>{},
    );
    expect(
      (shape! as RoundedRectangleBorder).borderRadius,
      const BorderRadius.all(Radius.circular(12)),
    );
    final bottomGap = find.byKey(const ValueKey('planner-calendar-bottom-gap'));
    expect(tester.getSize(bottomGap).height, 24);
    expect(find.byTooltip('Settings'), findsNothing);
    expect(find.byTooltip('Study history'), findsNothing);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    for (final key in [
      'planner-smart-session',
      'planner-new-session',
      'planner-new-event',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
    await openCalendarEntry(tester, StudyEntryKind.event);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
