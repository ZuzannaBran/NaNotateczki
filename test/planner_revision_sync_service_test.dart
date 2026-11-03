import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/planner_sync_service.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

void main() {
  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('v2 planner uses revisions despite clock skew and stores ACKs', () async {
    final storage = <String, String>{};
    textStorageReadOverride = (key) async => storage[key];
    textStorageWriteOverride = (key, text) async => storage[key] = text;
    final plannerFiles = <String, String>{};
    final planner = StudyPlannerController(
      read: (key) async => plannerFiles[key],
      write: (key, value) async => plannerFiles[key] = value,
      clock: () => DateTime.utc(2032, 1, 1),
      autoTick: false,
    );
    await planner.load();
    addTearDown(planner.dispose);
    final server = <String, Map<String, dynamic>>{};
    var writes = 0;
    final transport = MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path == '/v2/planner/entries') {
        return http.Response(
          jsonEncode({'entries': server.values.toList(), 'next': null}),
          200,
        );
      }
      if (request.method == 'PUT' &&
          request.url.path.startsWith('/v2/planner/entries/')) {
        writes++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final id = request.url.pathSegments.last;
        final previous = server[id];
        expect(body['expectedRevision'], previous?['revision'] ?? 0);
        final revision = (previous?['revision'] as int? ?? 0) + 1;
        final record = {
          'id': id,
          'revision': revision,
          'deleted': body['deleted'],
          'entry': body['entry'],
          'modifiedAt': '2026-11-03T00:00:00Z',
        };
        server[id] = record;
        return http.Response(jsonEncode(record), 200);
      }
      return http.Response('{}', 404);
    });
    final api = ApiClient(
      baseUri: Uri.parse('http://localhost:18080'),
      httpClient: transport,
    )..setAccessToken('test-token');
    addTearDown(api.close);
    final session = AccountSessionController(api)
      ..mode = AccountDataMode.account
      ..userId = 'account-1';
    addTearDown(session.dispose);
    final sync = PlannerSyncService(
      apiClient: api,
      session: session,
      planner: planner,
      useRevisions: true,
    );

    final entry = planner.create(
      title: 'Lecture',
      kind: StudyEntryKind.event,
      scheduledAt: DateTime(2026, 11, 4, 10),
    );
    await sync.syncNow();
    expect(writes, 1);
    await sync.syncNow();
    expect(writes, 1);
    final key = StorageNamespace.account('account-1')
        .fileKey('planner_revisions.json');
    expect(storage[key], contains('"revision":1'));

    planner.edit(
      entry.id,
      title: 'Lecture moved',
      description: 'Room A',
      scheduledAt: DateTime(2026, 11, 5, 10),
      minutes: 60,
      technique: StudyTechnique.custom,
    );
    await sync.syncNow();
    expect(writes, 2);
    expect(server[entry.id]!['revision'], 2);

    // A remote edit with an earlier wall clock still takes precedence over
    // a clean local record.
    final changed = Map<String, dynamic>.from(
      server[entry.id]!['entry'] as Map,
    )..['title'] = 'From another device';
    server[entry.id] = {
      ...server[entry.id]!,
      'revision': 3,
      'entry': changed,
      'modifiedAt': '2026-01-01T00:00:00Z',
    };
    await sync.syncNow();
    expect(planner.sessions.single.title, 'From another device');
    expect(writes, 2);
  });

  test('unsynchronized local edit is not erased by a conflicting revision',
      () async {
    final storage = <String, String>{};
    textStorageReadOverride = (key) async => storage[key];
    textStorageWriteOverride = (key, value) async => storage[key] = value;
    final plannerFiles = <String, String>{};
    final planner = StudyPlannerController(
      read: (key) async => plannerFiles[key],
      write: (key, value) async => plannerFiles[key] = value,
      autoTick: false,
    );
    await planner.load();
    addTearDown(planner.dispose);
    final entry = planner.create(
      title: 'Unsent local',
      scheduledAt: DateTime(2026, 11, 4),
      kind: StudyEntryKind.event,
    );
    final remote = {
      'id': entry.id,
      'revision': 1,
      'modifiedAt': '2026-11-03T00:00:00Z',
      'deleted': false,
      'entry': {...entry.toJson(), 'title': 'Other device'},
    };
    final api = ApiClient(
      baseUri: Uri.parse('http://localhost:18080'),
      httpClient: MockClient((request) async => http.Response(
        jsonEncode({'entries': [remote], 'next': null}), 200,
      )),
    )..setAccessToken('test-token');
    addTearDown(api.close);
    final session = AccountSessionController(api)
      ..mode = AccountDataMode.account
      ..userId = 'account-1';
    addTearDown(session.dispose);
    final sync = PlannerSyncService(
      apiClient: api, session: session, planner: planner, useRevisions: true,
    );

    await expectLater(sync.syncNow(), throwsStateError);
    expect(planner.sessions.single.title, 'Unsent local');
  });
}
