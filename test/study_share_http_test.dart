import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/live_web_sync_service.dart';
import 'package:program/data/sync/study_share_service.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

import 'support/native_test_documents.dart';

const _sessionId = 'e5b63a5e-82f3-4a2a-9c57-16255f4e4431';

ApiClient _api(Future<http.Response> Function(http.Request) handler) {
  return ApiClient(
    baseUri: Uri.parse('https://api.example.test'),
    httpClient: MockClient(handler),
  );
}

http.Response _loginResponse() {
  return http.Response(
    jsonEncode({
      'accessToken': 'owner-access-token',
      'refreshToken': 'refresh-token-with-at-least-forty-characters',
      'expiresIn': 600,
      'userId': 'owner-1',
      'username': 'owner',
    }),
    200,
  );
}

ActiveStudyShare _activeShare() => ActiveStudyShare(
  id: _sessionId,
  documentUid: 'original-uid',
  title: 'Original note',
  expiresAt: DateTime.utc(2027, 1, 1),
);

Future<({
  StudyShareService service,
  AccountSessionController session,
  LiveWebSyncService liveSync,
  NotebookRepository repository,
})>
_makeOwner(Future<http.Response> Function(http.Request) handler) async {
  final api = _api((request) async {
    if (request.url.path == '/v1/auth/login') {
      return _loginResponse();
    }
    return handler(request);
  });
  final session = AccountSessionController(api);
  await session.login('owner', 'a-secure-password');
  final database = NotesDatabase(NativeDatabase.memory());
  final repository = NotebookRepository(database);
  final liveSync = LiveWebSyncService(
    repository: repository,
    apiClient: api,
    session: session,
  );
  addTearDown(() async {
    liveSync.dispose();
    session.dispose();
    await database.close();
    api.close();
  });
  return (
    service: StudyShareService(
      session: session,
      liveSync: liveSync,
      repository: repository,
    ),
    session: session,
    liveSync: liveSync,
    repository: repository,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();

  setUp(() {
    textStorageReadOverride = (_) async => null;
    textStorageWriteOverride = (_, _) async {};
  });
  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('guest joins with a password, without an owner access token', () async {
    late http.Request captured;
    final api = _api((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'ticket': 'guest-ticket',
          'title': 'Biology',
          'revision': 3,
          'expiresAt': '2027-01-01T00:00:00Z',
        }),
        200,
      );
    });
    final guest = StudyShareGuestClient(apiClient: api);
    addTearDown(guest.close);

    final result = await guest.join(_sessionId, 'session-password');

    expect(result['ticket'], 'guest-ticket');
    expect(result['revision'], 3);
    expect(captured.method, 'POST');
    expect(captured.url.path, '/v1/study-shares/$_sessionId/join');
    expect(captured.url.query, isEmpty);
    expect(captured.headers.containsKey('authorization'), isFalse);
    expect(jsonDecode(captured.body), {'password': 'session-password'});
  });

  test('wrong guest password remains an HTTP 401', () async {
    final guest = StudyShareGuestClient(
      apiClient: _api((_) async => http.Response(
        jsonEncode({'detail': 'Incorrect session password.'}),
        401,
      )),
    );
    addTearDown(guest.close);

    await expectLater(
      guest.join(_sessionId, 'invalid'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'status', 401)
            .having((error) => error.message, 'message',
                'Incorrect session password.'),
      ),
    );
  });

  test('session expiry and rate limit propagate instead of retrying', () async {
    for (final status in [410, 429]) {
      var calls = 0;
      final guest = StudyShareGuestClient(
        apiClient: _api((_) async {
          calls++;
          return http.Response('{"detail":"Unavailable"}', status);
        }),
      );
      await expectLater(
        guest.join(_sessionId, 'password'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode, 'status', status,
          ),
        ),
      );
      expect(calls, 1);
      guest.close();
    }
  });

  test('malformed join responses are rejected without a ticket', () async {
    for (final payload in [
      <String, dynamic>{},
      <String, dynamic>{'ticket': 123, 'title': 't', 'revision': 1},
      <String, dynamic>{'ticket': 'token', 'title': 7, 'revision': 1},
      <String, dynamic>{'ticket': 'token', 'title': 't', 'revision': '1'},
    ]) {
      final guest = StudyShareGuestClient(
        apiClient: _api((_) async => http.Response(jsonEncode(payload), 200)),
      );
      await expectLater(
        guest.join(_sessionId, 'password'),
        throwsA(isA<FormatException>()),
      );
      guest.close();
    }
  });

  test('guest frame retains ticket and binary PNG bytes', () async {
    late http.Request captured;
    final frame = Uint8List.fromList([137, 80, 78, 71, 0, 255, 42]);
    final guest = StudyShareGuestClient(
      apiClient: _api((request) async {
        captured = request;
        return http.Response.bytes(frame, 200, headers: {
          'content-type': 'image/png',
        });
      }),
    );
    addTearDown(guest.close);

    final received = await guest.frame(_sessionId, 'private-guest-ticket');

    expect(received, orderedEquals(frame));
    expect(captured.method, 'GET');
    expect(captured.url.path, '/v1/study-shares/$_sessionId/frame');
    expect(captured.headers['authorization'], 'Bearer private-guest-ticket');
    expect(captured.url.query, isEmpty);
  });

  test('revoked guest frame is rejected and not shown as valid', () async {
    final guest = StudyShareGuestClient(
      apiClient: _api((_) async =>
          http.Response('{"detail":"Session has ended."}', 410)),
    );
    addTearDown(guest.close);

    await expectLater(
      guest.frame(_sessionId, 'expired-ticket'),
      throwsA(
        isA<ApiException>().having((error) => error.statusCode, 'status', 410),
      ),
    );
  });

  test('guest websocket uses WSS and does not place tickets in URL', () {
    final guest = StudyShareGuestClient(
      apiClient: _api((_) async => http.Response('', 500)),
    );
    addTearDown(guest.close);

    final uri = guest.eventsUri(_sessionId);
    expect(uri.scheme, 'wss');
    expect(uri.host, 'api.example.test');
    expect(uri.path, '/v1/study-shares/$_sessionId/events');
    expect(uri.query, isEmpty);
    expect(uri.userInfo, isEmpty);
  });

  test('local loopback uses WS but public plaintext is rejected', () {
    final guest = StudyShareGuestClient(
      apiClient: ApiClient(
        baseUri: Uri.parse('http://127.0.0.1:18080'),
        httpClient: MockClient((_) async => http.Response('', 500)),
      ),
    );
    addTearDown(guest.close);
    expect(guest.eventsUri(_sessionId).scheme, 'ws');
    expect(
      () => ApiClient(baseUri: Uri.parse('http://api.example.test')),
      throwsFormatException,
    );
  });

  test('invitation link retains identifier without secret parameters', () {
    final share = _activeShare();
    final uri = Uri.parse(share.link);
    expect(uri.path, '/share/$_sessionId');
    expect(uri.query, isEmpty);
    expect(uri.fragment, isEmpty);
    expect(share.documentUid, 'original-uid');
  });

  test('owner publish uploads raw PNG with owner bearer authentication',
      () async {
    late http.Request captured;
    final harness = await _makeOwner((request) async {
      captured = request;
      return http.Response('', 204);
    });
    final frame = Uint8List.fromList([1, 2, 3, 255]);

    await harness.service.publish(_activeShare(), frame);

    expect(captured.method, 'PUT');
    expect(captured.url.path, '/v1/study-shares/$_sessionId/frame');
    expect(captured.bodyBytes, orderedEquals(frame));
    expect(captured.headers['authorization'], 'Bearer owner-access-token');
    expect(captured.headers['content-type'], 'image/png');
  });

  test('extension preserves the original invitation and document', () async {
    final harness = await _makeOwner((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/study-shares/$_sessionId/extend');
      expect(request.headers['authorization'], 'Bearer owner-access-token');
      return http.Response(
        jsonEncode({'expiresAt': '2027-01-01T04:00:00Z'}),
        200,
      );
    });

    final before = _activeShare();
    final after = await harness.service.extend(before);

    expect(after.id, before.id);
    expect(after.link, before.link);
    expect(after.documentUid, before.documentUid);
    expect(after.expiresAt, DateTime.utc(2027, 1, 1, 4));
  });

  test('invalid extension response fails rather than losing session', () async {
    final harness = await _makeOwner((request) async =>
        http.Response(jsonEncode({'expiresAt': null}), 200));
    await expectLater(
      harness.service.extend(_activeShare()),
      throwsA(isA<FormatException>()),
    );
  });

  test('sharing requires login and enabled Web sync', () async {
    final api = _api((_) async {
      fail('The create endpoint must not be contacted.');
    });
    final session = AccountSessionController(api);
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final sync = LiveWebSyncService(
      repository: repository, apiClient: api, session: session,
    );
    addTearDown(() async {
      sync.dispose();
      session.dispose();
      await database.close();
      api.close();
    });
    final service = StudyShareService(
      session: session, liveSync: sync, repository: repository,
    );

    await expectLater(
      service.create(documentUid: 'uid', title: 'Note', password: 'password'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      service.end(_activeShare()),
      throwsA(isA<StateError>()),
    );
  });

  test('logged-in owner cannot share without starting Web sync', () async {
    final harness = await _makeOwner((_) async {
      fail('An unsynchronized notebook must not be shared.');
    });

    await expectLater(
      harness.service.create(
        documentUid: 'original-uid',
        title: 'Original note',
        password: 'study-password',
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      harness.service.end(_activeShare()),
      throwsA(isA<StateError>()),
    );
  });

  test('share link is created only after uploading owner document', () async {
    final requests = <String>[];
    final harness = await _makeOwner((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.url.path == '/v1/sync/bootstrap') {
        return http.Response(jsonEncode({'cursor': 0, 'notebooks': []}), 200);
      }
      if (request.url.path == '/v1/sync/changes') {
        return http.Response(jsonEncode({'cursor': 0, 'changes': []}), 200);
      }
      if (request.method == 'PUT' &&
          request.url.path.startsWith('/v1/sync/notebooks/')) {
        return http.Response(jsonEncode({'revision': 1}), 200);
      }
      if (request.url.path == '/v1/study-shares' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'id': _sessionId,
            'expiresAt': '2027-01-01T00:00:00Z',
          }),
          201,
        );
      }
      if (request.url.path == '/v1/study-shares/$_sessionId' &&
          request.method == 'DELETE') {
        return http.Response('', 204);
      }
      fail('Unexpected HTTP call: ${request.method} ${request.url}');
    });
    final original = await harness.repository.createNotebook();
    await harness.liveSync.start(InitialSyncPolicy.uploadLocal);

    final share = await harness.service.create(
      documentUid: original.uid,
      title: original.title,
      password: 'study-password',
    );
    await harness.service.end(share);

    final upload = requests.indexWhere(
      (value) => value.startsWith('PUT /v1/sync/notebooks/'),
    );
    final created = requests.indexOf('POST /v1/study-shares');
    final ended = requests.indexOf('DELETE /v1/study-shares/$_sessionId');
    expect(upload, greaterThanOrEqualTo(0));
    expect(created, greaterThan(upload));
    expect(ended, greaterThan(created));
    expect(await harness.repository.getNotebook(original.uid), isNotNull);
  });

  test('failed owner upload prevents creating a guest link', () async {
    var linkRequests = 0;
    final harness = await _makeOwner((request) async {
      if (request.url.path == '/v1/sync/bootstrap') {
        return http.Response(jsonEncode({'cursor': 0, 'notebooks': []}), 200);
      }
      if (request.url.path == '/v1/sync/changes') {
        return http.Response(jsonEncode({'cursor': 0, 'changes': []}), 200);
      }
      if (request.method == 'PUT' &&
          request.url.path.startsWith('/v1/sync/notebooks/')) {
        return http.Response('{"detail":"Storage unavailable"}', 503);
      }
      if (request.url.path == '/v1/study-shares') {
        linkRequests++;
        return http.Response('{}', 201);
      }
      fail('Unexpected HTTP call: ${request.method} ${request.url}');
    });
    final original = await harness.repository.createNotebook();
    await harness.liveSync.start(InitialSyncPolicy.uploadLocal);

    await expectLater(
      harness.service.create(
        documentUid: original.uid,
        title: original.title,
        password: 'study-password',
      ),
      throwsA(isA<StateError>()),
    );

    expect(linkRequests, 0);
    expect(await harness.repository.getNotebook(original.uid), isNotNull);
  });
}
