import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/planner_sync_service.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

void main() {
  test(
    'two systems reconcile creates, edits, deletes and late conflicts',
    () async {
    final server = <String, Map<String, dynamic>>{};
    final transport = MockClient((request) async {
      if (request.method == 'GET') {
        final after = request.url.queryParameters['after'] ?? '';
        final keys = server.keys.where((id) => id.compareTo(after) > 0)
            .toList()
          ..sort();
        final page = keys.take(200).toList();
        final next = keys.length > 200 ? page.last : null;
        return http.Response(jsonEncode({
          'entries': [for (final id in page) server[id]],
          'next': next,
        }), 200);
      }
      if (request.method == 'PUT') {
        final id = request.url.pathSegments.last;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final previous = server[id];
        final earlier = previous == null ||
            DateTime.parse(body['modifiedAt'] as String).isAfter(
              DateTime.parse(previous['modifiedAt'] as String),
            );
        if (earlier) {
          server[id] = {
            'id': id,
            'modifiedAt': body['modifiedAt'],
            'deleted': body['deleted'],
            'entry': body['entry'],
          };
        }
        return http.Response(jsonEncode(server[id]), 200);
      }
      return http.Response('{}', 404);
    });

    final stores = [<String, String>{}, <String, String>{}];
    final times = [
      DateTime.utc(2026, 11, 2, 9),
      DateTime.utc(2026, 11, 2, 9),
    ];
    final controllers = <StudyPlannerController>[];
    final apis = <ApiClient>[];
    final sessions = <AccountSessionController>[];
    final syncers = <PlannerSyncService>[];
    for (var i = 0; i < 2; i++) {
      final store = stores[i];
      final index = i;
      final controller = StudyPlannerController(
        read: (key) async => store[key],
        write: (key, value) async {
          store[key] = value;
        },
        clock: () => times[index],
        autoTick: false,
      );
      await controller.load();
      controllers.add(controller);
      final api = ApiClient(
        baseUri: Uri.parse('http://localhost:18080'),
        httpClient: transport,
      )..setAccessToken('test-token');
      final session = AccountSessionController(api)
        ..mode = AccountDataMode.account
        ..userId = 'user-one';
      apis.add(api);
      sessions.add(session);
      syncers.add(PlannerSyncService(
        apiClient: api,
        session: session,
        planner: controller,
      ));
    }

    final first = controllers[0];
    final second = controllers[1];
    final event = first.create(
      title: 'Lecture',
      scheduledAt: DateTime(2026, 11, 4, 10),
      kind: StudyEntryKind.event,
    );
    await syncers[0].syncNow();
    await syncers[1].syncNow();
    expect(second.sessions.single.title, 'Lecture');

    times[0] = times[0].add(const Duration(minutes: 1));
    first.edit(
      event.id,
      title: 'Lecture updated',
      description: 'Room 1',
      scheduledAt: DateTime(2026, 11, 4, 11),
      minutes: 60,
      technique: StudyTechnique.custom,
    );
    await syncers[0].syncNow();
    await syncers[1].syncNow();
    expect(second.sessions.single.title, 'Lecture updated');

    // Both devices edit offline. The later modification wins per entry.
    times[0] = times[0].add(const Duration(minutes: 1));
    first.edit(
      event.id,
      title: 'Earlier edit',
      description: '',
      scheduledAt: DateTime(2026, 11, 4, 12),
      minutes: 45,
      technique: StudyTechnique.custom,
    );
    times[1] = times[0].add(const Duration(minutes: 1));
    second.edit(
      event.id,
      title: 'Later edit',
      description: '',
      scheduledAt: DateTime(2026, 11, 4, 13),
      minutes: 45,
      technique: StudyTechnique.custom,
    );
    await syncers[0].syncNow();
    await syncers[1].syncNow();
    await syncers[0].syncNow();
    expect(first.sessions.single.title, 'Later edit');

    times[1] = times[1].add(const Duration(minutes: 1));
    second.delete(event.id);
    await syncers[1].syncNow();
    await syncers[0].syncNow();
    expect(first.sessions, isEmpty);
    expect(first.syncRecords[event.id]?['deleted'], true);

    for (final service in syncers) {
      service.stop();
    }
    for (final controller in controllers) {
      await controller.flush();
      controller.dispose();
    }
    for (final session in sessions) {
      session.dispose();
    }
    for (final api in apis) {
      api.close();
    }
    },
  );
}
