import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

void main() {
  late DateTime now;
  late Map<String, String> storage;
  late StudyPlannerController planner;

  setUp(() {
    now = DateTime(2026, 10, 9, 9);
    storage = {};
    planner = StudyPlannerController(
      autoTick: false,
      clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async { storage[key] = value; },
    );
  });

  tearDown(() async {
    await planner.flush();
    planner.dispose();
  });

  test('planned session can be edited, moved and persisted', () async {
    await planner.load();
    final item = planner.create(
      title: 'Maths', scheduledAt: DateTime(2026, 10, 10, 8),
      description: 'Algebra',
    );
    planner.move(item.id, DateTime(2026, 10, 12));
    planner.edit(
      item.id, title: 'Physics', description: 'Mechanics',
      scheduledAt: DateTime(2026, 10, 12, 8),
      minutes: 75, technique: StudyTechnique.custom,
    );
    await planner.flush();
    final json = jsonDecode(storage[StudyPlannerController.storageKey]!)
        as Map<String, dynamic>;
    expect((json['sessions'] as List).length, 1);
    expect(item.title, 'Physics');
    expect(item.description, 'Mechanics');
    expect(item.scheduledAt.day, 12);
    expect(item.minutes, 75);

    final loaded = StudyPlannerController(
      autoTick: false, clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async { storage[key] = value; },
    );
    await loaded.load();
    expect(loaded.sessions.single.title, 'Physics');
    expect(loaded.sessions.single.scheduledAt.day, 12);
    loaded.dispose();
  });

  test('timer pause, resume and rating preserve history', () async {
    await planner.load();
    final item = planner.create(
      title: 'Chemistry', scheduledAt: now, minutes: 2,
    );
    expect(planner.start(item.id), isTrue);
    now = now.add(const Duration(seconds: 42));
    expect(planner.secondsLeft(item), 78);
    expect(planner.pause(), isTrue);
    now = now.add(const Duration(minutes: 30));
    planner.tick();
    expect(planner.secondsLeft(item), 78);
    expect(item.status, StudyStatus.paused);
    expect(planner.resume(), isTrue);
    now = now.add(const Duration(seconds: 78));
    planner.tick();
    expect(item.status, StudyStatus.review);
    expect(planner.history, isEmpty);
    planner.rate(item.id, 4);
    expect(planner.history.single.productivity, 4);
    await planner.flush();
    expect(storage.values.single, contains('"completed"'));
  });

  test('overdue running session is recovered on next launch', () async {
    await planner.load();
    final item = planner.create(
      title: 'Biology', scheduledAt: now, minutes: 1,
    );
    planner.start(item.id);
    await planner.flush();
    now = now.add(const Duration(minutes: 15));
    final restored = StudyPlannerController(
      autoTick: false, clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async { storage[key] = value; },
    );
    await restored.load();
    expect(restored.active, isNull);
    expect(restored.pendingReviews, isEmpty);
    expect(restored.history.single.title, 'Biology');
    expect(restored.history.single.productivity, isNull);
    await restored.flush();
    restored.dispose();
  });

  test('smart Pomodoro advances focus, breaks and four rounds', () async {
    await planner.load();
    final item = planner.create(
      title: 'French', scheduledAt: now,
      technique: StudyTechnique.pomodoro,
    );
    planner.start(item.id);
    for (var round = 1; round <= 4; round++) {
      now = now.add(const Duration(minutes: 25));
      planner.tick();
      if (round == 4) {
        expect(item.status, StudyStatus.review);
      } else {
        expect(item.phase, StudyPhase.breakTime);
        expect(item.round, round);
        now = now.add(const Duration(minutes: 5));
        planner.tick();
        expect(item.phase, StudyPhase.focus);
        expect(item.round, round + 1);
      }
    }
    expect(item.totalFocusMinutes, 100);
    expect(planner.active, isNull);
  });

  test('overlapping start is rejected and cancelled sessions need rating',
      () async {
    await planner.load();
    final first = planner.create(
      title: 'First', scheduledAt: now,
    );
    final second = planner.create(
      title: 'Second', scheduledAt: now.add(const Duration(hours: 2)),
    );
    expect(planner.start(first.id), isTrue);
    expect(planner.start(second.id), isFalse);
    expect(() => planner.delete(first.id), throwsStateError);
    expect(planner.stop(), isTrue);
    expect(first.status, StudyStatus.review);
    expect(planner.start(second.id), isTrue);
    planner.rate(first.id, 5);
    expect(planner.history.single.title, 'First');
  });

  test('dismissed rating is saved in history without further prompts',
      () async {
    await planner.load();
    final item = planner.create(title: 'Unrated', scheduledAt: now);
    expect(planner.start(item.id), isTrue);
    expect(planner.stop(), isTrue);
    expect(planner.pendingReviews.single.id, item.id);

    planner.skipRating(item.id);
    planner.skipRating(item.id);
    expect(planner.pendingReviews, isEmpty);
    expect(planner.history.single.productivity, isNull);
    expect(planner.history.single.status, StudyStatus.completed);

    await planner.flush();
    final restored = StudyPlannerController(
      autoTick: false,
      clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async { storage[key] = value; },
    );
    await restored.load();
    expect(restored.pendingReviews, isEmpty);
    expect(restored.history.single.title, 'Unrated');
    expect(restored.history.single.productivity, isNull);
    await restored.flush();
    restored.dispose();
  });

  test('unrated legacy reviews become history when loaded', () async {
    await planner.load();
    final item = planner.create(title: 'Legacy', scheduledAt: now);
    planner.start(item.id);
    planner.stop();
    await planner.flush();

    final restored = StudyPlannerController(
      autoTick: false,
      clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async { storage[key] = value; },
    );
    await restored.load();
    expect(restored.pendingReviews, isEmpty);
    expect(restored.history.single.id, item.id);
    expect(restored.history.single.productivity, isNull);
    await restored.flush();
    final saved = jsonDecode(storage[StudyPlannerController.storageKey]!)
        as Map<String, dynamic>;
    expect((saved['sessions'] as List).single['status'], 'completed');
    restored.dispose();
  });

  test('unreadable history blocks destructive replacement', () async {
    storage[StudyPlannerController.storageKey] = '{broken';
    await planner.load();
    expect(planner.error, isNotNull);
    expect(
      () => planner.create(title: 'A', scheduledAt: now),
      throwsStateError,
    );
    await planner.flush();
    expect(storage[StudyPlannerController.storageKey], '{broken');
  });
}
