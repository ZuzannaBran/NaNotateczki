import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/error/app_error_log.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/diagnostics_upload_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> stored;
  setUp(() {
    stored = {};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    AppErrorLog.instance.clear();
  });

  tearDown(() {
    AppErrorLog.instance.clear();
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('server 5xx enters Errors and reaches private diagnostics', () async {
    final uploads = <Map<String, dynamic>>[];
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/changes') {
          return http.Response('{"detail":"Internal server error."}', 503);
        }
        if (request.url.path == '/v2/reports/diagnostics') {
          expect(request.method, 'PUT');
          expect(request.headers['authorization'], 'Bearer test-token');
          uploads.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{"stored":true}', 200);
        }
        fail('Unexpected API request: ${request.url.path}');
      }),
    )..setAccessToken('test-token');
    addTearDown(client.close);

    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-one';
    addTearDown(session.dispose);
    final uploader = DiagnosticsUploadService(
      apiClient: client,
      session: session,
    );
    addTearDown(uploader.dispose);

    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        client.get('/v1/sync/changes'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            503,
          ),
        ),
      );
    }

    final log = AppErrorLog.instance;
    expect(log.entries, hasLength(1));
    expect(log.entries.single.source, 'Server API');
    expect(log.entries.single.occurrences, 2);
    expect(log.entries.single.error, contains('HTTP 503'));
    expect(log.entries.single.error, contains('/v1/sync/changes'));
    expect(log.entries.single.error, isNot(contains('test-token')));

    await uploader.uploadNow();
    expect(uploads, hasLength(1));
    expect(uploads.single['errors'], contains('HTTP 503'));
    expect(uploads.single['errors'], contains('(x2)'));
    expect(uploads.single['deviceId'], isNotEmpty);
    expect(uploads.single['system'], isNotEmpty);
    await uploader.uploadNow();
    expect(uploads, hasLength(1));

    final saved = jsonDecode(stored['app_error_log.json']!) as List<dynamic>;
    expect((saved.single as Map<String, dynamic>)['occurrences'], 2);
  });

  test('diagnostics failures do not recurse', () async {
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/sync/notebooks/note') {
          return http.Response('{"detail":"Conflict"}', 409);
        }
        if (request.url.path == '/v2/reports/diagnostics') {
          return http.Response('{"detail":"Service unavailable"}', 503);
        }
        if (request.url.path == '/v1/sync/bootstrap') {
          throw http.ClientException('Network unreachable');
        }
        fail('Unexpected API request');
      }),
    )..setAccessToken('test-token');
    addTearDown(client.close);

    await expectLater(
      client.get('/v1/sync/notebooks/note'),
      throwsA(isA<ApiException>()),
    );
    expect(AppErrorLog.instance.isEmpty, isTrue);

    await expectLater(
      client.putJson('/v2/reports/diagnostics', {}),
      throwsA(isA<ApiException>()),
    );
    expect(AppErrorLog.instance.isEmpty, isTrue);

    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        client.get('/v1/sync/bootstrap'),
        throwsA(isA<http.ClientException>()),
      );
    }
    expect(AppErrorLog.instance.entries, hasLength(1));
    expect(AppErrorLog.instance.entries.single.occurrences, 2);
    expect(
      AppErrorLog.instance.entries.single.error,
      contains('Connection failure'),
    );
    expect(
      AppErrorLog.instance.entries.single.error,
      isNot(contains('Network unreachable')),
    );
  });
}
