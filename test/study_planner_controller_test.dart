import 'dart:async';
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
      write: (key, value) async {
        storage[key] = value;
      },
    );
  });

  tearDown(() async {
    await planner.flush();
    planner.dispose();
  });

  for (final readFails in [false, true]) {
    test(
      'late planner load is ignored after dispose, failure=$readFails',
      () async {
        final read = Completer<String?>();
        final writes = <String>[];
        var notifications = 0;
        final closing = StudyPlannerController(
          read: (_) => read.future,
          write: (_, value) async => writes.add(value),
        )..addListener(() => notifications++);
        final loading = closing.load();
        closing.dispose();
        if (readFails) {
          read.completeError(StateError('Storage unavailable'));
        } else {
          final review = StudySession(
            id: 'unfinished-review',
            title: 'Revision',
            scheduledAt: now,
            minutes: 30,
          )..status = StudyStatus.review;
          read.complete(
            jsonEncode({
              'version': 1,
              'sessions': [review.toJson()],
            }),
          );
        }
        await expectLater(loading, completes);
        await closing.flush();
        expect(closing.sessions, isEmpty);
        expect(closing.isLoaded, isFalse);
        expect(notifications, 0);
        expect(writes, isEmpty);
        expect(closing.error, isNull);
      },
    );
  }

  test('calendar event shares editing and persistence but cannot start', () async {
    await planner.load();
    final event = planner.create(
      kind: StudyEntryKind.event,
      title: 'Exam',
      scheduledAt: DateTime(2026, 10, 10, 9),
      minutes: 90,
      description: 'Room 2',
    );
    expect(planner.start(event.id), isFalse);
    expect(planner.active, isNull);
    planner.move(event.id, DateTime(2026, 10, 11));
    planner.edit(
      event.id,
      title: 'Exam changed',
      description: 'Room 3',
      scheduledAt: DateTime(2026, 10, 11, 9),
      minutes: 120,
      technique: StudyTechnique.custom,
    );
    await planner.flush();
    final restored = StudyPlannerController(
      autoTick: false,
      clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async { storage[key] = value; },
    );
    await restored.load();
    expect(restored.sessions.single.kind, StudyEntryKind.event);
    expect(restored.sessions.single.title, 'Exam changed');
    expect(restored.sessions.single.minutes, 120);
    expect(restored.sessions.single.description, 'Room 3');
    expect(restored.start(event.id), isFalse);
    restored.delete(event.id);
    expect(restored.sessions, isEmpty);
    await restored.flush();
    restored.dispose();
  });

  test('recurring events appear only in calendar and persist as one series',
      () async {
    await planner.load();
    final event = planner.create(
      kind: StudyEntryKind.event,
      title: 'Wednesday lecture',
      scheduledAt: DateTime(2026, 10, 21, 13),
      minutes: 90,
      repeat: StudyRepeat.weekly,
      repeatEvery: 2,
    );
    expect(planner.upcoming, isEmpty);
    final entries = planner.calendarEntries(
      DateTime(2026, 10, 20),
      DateTime(2026, 11, 20),
    );
    expect(entries.map((entry) => entry.scheduledAt.day), [21, 4, 18]);
    expect(entries.map((entry) => entry.scheduledAt.weekday).toSet(), {
      DateTime.wednesday,
    });
    expect(entries.map((entry) => entry.id).toSet().length, 3);
    expect(planner.originalFor(entries.last).id, event.id);

    await planner.flush();
    final restored = StudyPlannerController(
      autoTick: false,
      clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async {},
    );
    await restored.load();
    expect(restored.sessions, hasLength(1));
    expect(restored.sessions.single.repeat, StudyRepeat.weekly);
    expect(restored.sessions.single.repeatEvery, 2);
    expect(
      restored.calendarEntries(DateTime(2026, 11, 4),
          DateTime(2026, 11, 4)),
      hasLength(1),
    );
    restored.dispose();
  });

  test('all-day and multi-day events cover every occupied calendar day',
      () async {
    await planner.load();
    final allDay = planner.create(
      kind: StudyEntryKind.event,
      title: 'Conference',
      scheduledAt: DateTime(2026, 10, 20),
      minutes: 1440,
      allDay: true,
      eventEndDate: DateTime(2026, 10, 22),
    );
    expect(allDay.scheduledDurationMinutes, 3 * 1440);
    expect(
      planner.calendarEntries(DateTime(2026, 10, 21),
          DateTime(2026, 10, 21)).single.id,
      allDay.id,
    );
    expect(
      planner.calendarEntries(DateTime(2026, 10, 23),
          DateTime(2026, 10, 23)),
      isEmpty,
    );
    final evening = planner.create(
      kind: StudyEntryKind.event,
      title: 'Hackathon',
      scheduledAt: DateTime(2026, 10, 25, 23, 30),
      minutes: 60,
      eventEndDate: DateTime(2026, 10, 26),
    );
    expect(evening.scheduledDurationMinutes, 1500);
    expect(
      planner.calendarEntries(DateTime(2026, 10, 26),
          DateTime(2026, 10, 26)).single.id,
      evening.id,
    );
    await planner.flush();
    final serialized = jsonDecode(
      storage[StudyPlannerController.storageKey]!,
    ) as Map<String, dynamic>;
    expect((serialized['sessions'] as List), hasLength(2));
    expect((serialized['sessions'] as List).first['allDay'], isTrue);
    expect(
      StudySession.fromJson(
        (serialized['sessions'] as List).first as Map<String, dynamic>,
      ).eventEndDate,
      DateTime(2026, 10, 22),
    );
  });

  test('old event values without recurrence default to single-day',
      () {
    final event = StudySession.fromJson({
      'id': 'old-event',
      'kind': 'event',
      'title': 'Meeting',
      'scheduledAt': now.toIso8601String(),
      'minutes': 40,
    });
    expect(event.allDay, isFalse);
    expect(event.eventEndDate, isNull);
    expect(event.repeat, StudyRepeat.none);
    expect(event.repeatEvery, 1);
  });

  test('old sessions without kind remain regular sessions', () {
    final legacy = StudySession.fromJson({
      'id': 'legacy',
      'title': 'Legacy',
      'scheduledAt': now.toIso8601String(),
      'minutes': 45,
    });
    expect(legacy.kind, StudyEntryKind.session);
  });

  test('planned session can be edited, moved and persisted', () async {
    await planner.load();
    final item = planner.create(
      title: 'Maths',
      scheduledAt: DateTime(2026, 10, 10, 8),
      description: 'Algebra',
    );
    planner.move(item.id, DateTime(2026, 10, 12));
    planner.edit(
      item.id,
      title: 'Physics',
      description: 'Mechanics',
      scheduledAt: DateTime(2026, 10, 12, 8),
      minutes: 75,
      technique: StudyTechnique.custom,
    );
    await planner.flush();
    final json =
        jsonDecode(storage[StudyPlannerController.storageKey]!)
            as Map<String, dynamic>;
    expect((json['sessions'] as List).length, 1);
    expect(item.title, 'Physics');
    expect(item.description, 'Mechanics');
    expect(item.scheduledAt.day, 12);
    expect(item.minutes, 75);

    final loaded = StudyPlannerController(
      autoTick: false,
      clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async {
        storage[key] = value;
      },
    );
    await loaded.load();
    expect(loaded.sessions.single.title, 'Physics');
    expect(loaded.sessions.single.scheduledAt.day, 12);
    loaded.dispose();
  });

  test('timer pause, resume and rating preserve history', () async {
    await planner.load();
    final item = planner.create(
      title: 'Chemistry',
      scheduledAt: now,
      minutes: 2,
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
    final item = planner.create(title: 'Biology', scheduledAt: now, minutes: 1);
    planner.start(item.id);
    await planner.flush();
    now = now.add(const Duration(minutes: 15));
    final restored = StudyPlannerController(
      autoTick: false,
      clock: () => now,
      read: (key) async => storage[key],
      write: (key, value) async {
        storage[key] = value;
      },
    );
    await restored.load();
    expect(restored.active, isNull);
    expect(restored.pendingReviews, isEmpty);
    expect(restored.history.single.title, 'Biology');
    expect(restored.history.single.productivity, isNull);
    await restored.flush();
    restored.dispose();
  });

  test(
    'smart blocks and colour persist and control focus transitions',
    () async {
      await planner.load();
      final item = planner.create(
        title: 'Custom Pomodoro',
        scheduledAt: now,
        technique: StudyTechnique.pomodoro,
        focusBlocks: 2,
        colorValue: 0xFF7491C4,
      );
      expect(item.focusBlocks, 2);
      expect(item.totalFocusMinutes, 50);
    expect(item.scheduledDurationMinutes, 55);
      expect(item.colorValue, 0xFF7491C4);

      planner.start(item.id);
      now = now.add(const Duration(minutes: 25));
      planner.tick();
      expect(item.phase, StudyPhase.breakTime);
      now = now.add(const Duration(minutes: 5));
      planner.tick();
      expect(item.round, 2);
      expect(item.phase, StudyPhase.focus);
      now = now.add(const Duration(minutes: 25));
      planner.tick();
      expect(item.status, StudyStatus.review);

      await planner.flush();
      final restored = StudyPlannerController(
        autoTick: false,
        clock: () => now,
        read: (key) async => storage[key],
        write: (key, value) async {
          storage[key] = value;
        },
      );
      await restored.load();
      expect(restored.sessions.single.focusBlocks, 2);
      expect(restored.sessions.single.colorValue, 0xFF7491C4);
      await restored.flush();
      restored.dispose();
    },
  );

  test('editing blocks and clearing a session colour persists', () async {
    await planner.load();
    final item = planner.create(
      title: 'Edit colours',
      scheduledAt: now,
      technique: StudyTechnique.focus50,
      colorValue: 0xFF264B91,
    );
    planner.edit(
      item.id,
      title: item.title,
      description: item.description,
      scheduledAt: item.scheduledAt,
      minutes: item.minutes,
      technique: StudyTechnique.focus50,
      focusBlocks: 3,
      colorValue: null,
      updateColor: true,
    );
    expect(item.focusBlocks, 3);
    expect(item.colorValue, isNull);
    await planner.flush();
    final saved = jsonDecode(
      storage[StudyPlannerController.storageKey]!,
    ) as Map<String, dynamic>;
    final session = (saved['sessions'] as List).single as Map;
    expect(session['focusBlocks'], 3);
    expect(session['colorValue'], isNull);
  });

  test('legacy sessions retain technique default blocks', () async {
    final legacy = StudySession(
      id: 'legacy',
      title: 'Old session',
      scheduledAt: now,
      minutes: 30,
      technique: StudyTechnique.pomodoro,
    ).toJson()
      ..remove('focusBlocks')
      ..remove('colorValue');
    storage[StudyPlannerController.storageKey] = jsonEncode({
      'version': 1,
      'sessions': [legacy],
    });
    await planner.load();
    expect(planner.sessions.single.focusBlocks, 4);
    expect(planner.sessions.single.colorValue, isNull);
  });

  test('smart Pomodoro advances focus, breaks and four rounds', () async {
    await planner.load();
    final item = planner.create(
      title: 'French',
      scheduledAt: now,
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

  test(
    'overlapping start is rejected and cancelled sessions need rating',
    () async {
      await planner.load();
      final first = planner.create(title: 'First', scheduledAt: now);
      final second = planner.create(
        title: 'Second',
        scheduledAt: now.add(const Duration(hours: 2)),
      );
      expect(planner.start(first.id), isTrue);
      expect(planner.start(second.id), isFalse);
      expect(() => planner.delete(first.id), throwsStateError);
      expect(planner.stop(), isTrue);
      expect(first.status, StudyStatus.review);
      expect(planner.start(second.id), isTrue);
      planner.rate(first.id, 5);
      expect(planner.history.single.title, 'First');
    },
  );

  test(
    'dismissed rating is saved in history without further prompts',
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
        write: (key, value) async {
          storage[key] = value;
        },
      );
      await restored.load();
      expect(restored.pendingReviews, isEmpty);
      expect(restored.history.single.title, 'Unrated');
      expect(restored.history.single.productivity, isNull);
      await restored.flush();
      restored.dispose();
    },
  );

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
      write: (key, value) async {
        storage[key] = value;
      },
    );
    await restored.load();
    expect(restored.pendingReviews, isEmpty);
    expect(restored.history.single.id, item.id);
    expect(restored.history.single.productivity, isNull);
    await restored.flush();
    final saved =
        jsonDecode(storage[StudyPlannerController.storageKey]!)
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
