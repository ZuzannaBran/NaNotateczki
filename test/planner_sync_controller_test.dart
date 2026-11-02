import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

void main() {
  test(
    'deletion tombstones survive restart and reject old offline edits',
    () async {
    final files = <String, String>{};
    var now = DateTime.utc(2026, 11, 2, 9);
    StudyPlannerController fresh() => StudyPlannerController(
      read: (key) async => files[key],
      write: (key, value) async {
        files[key] = value;
      },
      clock: () => now,
      autoTick: false,
    );

    final first = fresh();
    await first.load();
    final entry = first.create(
      title: 'Meeting',
      kind: StudyEntryKind.event,
      scheduledAt: DateTime(2026, 11, 3, 10),
    );
    await first.flush();
    final old = first.syncRecords[entry.id]!;
    now = now.add(const Duration(minutes: 5));
    first.delete(entry.id);
    await first.flush();
    expect(first.syncRecords[entry.id]?['deleted'], true);
    first.dispose();

    final second = fresh();
    await second.load();
    second.applyRemoteRecords([old]);
    expect(second.sessions, isEmpty);
    expect(second.syncRecords[entry.id]?['deleted'], true);
    final later = Map<String, dynamic>.from(old);
    later['modifiedAt'] = now
        .add(const Duration(minutes: 1))
        .toIso8601String();
    second.applyRemoteRecords([later]);
    await second.flush();
    expect(second.sessions.single.title, 'Meeting');
    expect(
      jsonDecode(files[StudyPlannerController.storageKey]!)['version'],
      2,
    );
    second.dispose();
    },
  );

  test('separate entries merge and older timestamps are ignored', () async {
    final files = <String, String>{};
    final controller = StudyPlannerController(
      read: (key) async => files[key],
      write: (key, value) async {
        files[key] = value;
      },
      autoTick: false,
    );
    await controller.load();
    final session = controller.create(
      title: 'Focus',
      scheduledAt: DateTime(2026, 11, 2),
    );
    await controller.flush();
    final old = controller.syncRecords[session.id]!;
    final stale = Map<String, dynamic>.from(old);
    stale['modifiedAt'] = '2020-01-01T00:00:00Z';
    stale['entry'] = {
      ...(old['entry'] as Map<String, dynamic>),
      'title': 'Stale',
    };
    controller.applyRemoteRecords([stale]);
    expect(controller.sessions.single.title, 'Focus');

    final remoteEntry = {
      ...(old['entry'] as Map<String, dynamic>),
      'id': 'remote',
      'title': 'Remote focus',
    };
    controller.applyRemoteRecords([
      {
        'id': 'remote',
        'modifiedAt': DateTime.now().toUtc().toIso8601String(),
        'deleted': false,
        'entry': remoteEntry,
      },
    ]);
    expect(
      controller.sessions.map((entry) => entry.id).toSet(),
      {session.id, 'remote'},
    );
    await controller.flush();
    controller.dispose();
  });
}
