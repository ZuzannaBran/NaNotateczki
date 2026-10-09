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
    await tester.tap(find.byKey(const ValueKey('productivity-5')));
    await tester.pumpAndSettle();
    expect(planner.history.single.productivity, 5);
    expect(tester.takeException(), isNull);
  });
}
