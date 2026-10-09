import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/features/planner/presentation/planner_screen.dart';
import 'package:program/features/planner/presentation/study_timer_widgets.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

void main() {
  late StudyPlannerController planner;

  setUp(() async {
    planner = StudyPlannerController(
      autoTick: false,
      read: (_) async => null,
      write: (_, _) async {},
    );
    await planner.load();
  });

  tearDown(() async {
    await planner.flush();
    planner.dispose();
  });

  testWidgets('calendar changes between today week and month', (
    tester,
  ) async {
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
    expect(find.text('Mon'), findsWidgets);
    await tester.tap(find.text('Today').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Calculus'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar timer starts pauses and rates a session', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<StudyPlannerController>.value(
        value: planner,
        child: const MaterialApp(
          home: Scaffold(body: StudyTimerCard()),
        ),
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
  });

  testWidgets('skipping a rating never leaves a sidebar reminder', (
    tester,
  ) async {
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
        child: const MaterialApp(
          home: Scaffold(body: StudyTimerCard()),
        ),
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
  });

  testWidgets('closing the rating dialog also finishes without rating', (
    tester,
  ) async {
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
        child: const MaterialApp(
          home: Scaffold(body: StudyTimerCard()),
        ),
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
  });

  testWidgets('history shows star counts and never null over five', (
    tester,
  ) async {
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
    await tester.tap(find.byTooltip('Study history'));
    await tester.pumpAndSettle();

    expect(find.textContaining('★★★☆☆'), findsWidgets);
    expect(find.textContaining('Not rated'), findsWidgets);
    expect(find.textContaining('null/5'), findsNothing);
    expect(find.textContaining('Rate now'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
