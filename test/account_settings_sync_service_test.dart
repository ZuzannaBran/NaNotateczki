import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/core/storage/active_storage_namespace.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/account_settings_sync_service.dart';
import 'package:program/data/sync/api_client.dart';

void main() {
  test('stopAndDrain waits for an old settings HTTP request', () async {
    const user = 'settings-shutdown-account';
    ActiveStorageNamespace.activate(StorageNamespace.account(user));
    final files = <String, String>{};
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async => files[key] = value;
    addTearDown(() {
      textStorageReadOverride = null;
      textStorageWriteOverride = null;
    });
    final started = Completer<void>();
    final release = Completer<http.Response>();
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) {
        if (!started.isCompleted) {
          started.complete();
        }
        return release.future;
      }),
    )..setAccessToken('test-token');
    addTearDown(api.close);
    final session = AccountSessionController(api)
      ..mode = AccountDataMode.account
      ..userId = user;
    addTearDown(session.dispose);
    final service = AccountSettingsSyncService(
      apiClient: api,
      session: session,
    );

    final running = service.syncNow();
    await started.future;
    var drained = false;
    final stop = service.stopAndDrain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    release.complete(http.Response('{"settings":{}}', 200));
    await Future.wait([running, stop]);
    expect(drained, isTrue);
    expect(files, isEmpty);
  });

  test(
    'first v2 settings pass keeps an offline edit using the v1 CAS base',
    () async {
      const user = 'historical-settings';
      ActiveStorageNamespace.activate(StorageNamespace.account(user));
      final suffix = sha256
          .convert(utf8.encode(user))
          .toString()
          .substring(0, 16);
      final files = <String, String>{
        'app_prefs.json': '{"darkMode":true}',
        'account_settings_cursor_$suffix.json': jsonEncode({
          'version': 1,
          'settings': {
            'appPreferences': {
              'revision': 4,
              'value': {'darkMode': false},
            },
          },
        }),
      };
      textStorageReadOverride = (key) async => files[key];
      textStorageWriteOverride = (key, value) async => files[key] = value;
      final api = ApiClient(
        baseUri: Uri.parse('https://api.example.test'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'settings': {
                  'appPreferences': {
                    'revision': 4,
                    'value': {'darkMode': false},
                  },
                },
              }),
              200,
            );
          }
          expect(request.method, 'PUT');
          expect(request.url.path, '/v2/account-settings/appPreferences');
          expect(jsonDecode(request.body), {
            'expectedRevision': 4,
            'value': {'darkMode': true},
          });
          return http.Response('{"revision":5,"value":{"darkMode":true}}', 200);
        }),
      )..setAccessToken('test-token');
      addTearDown(api.close);
      final session = AccountSessionController(api)
        ..mode = AccountDataMode.account
        ..userId = user;
      addTearDown(session.dispose);
      final service = AccountSettingsSyncService(
        apiClient: api,
        session: session,
      );
      await service.syncNow();
      expect(files['app_prefs.json'], '{"darkMode":true}');
      expect(
        files['account_settings_v2_cursor_$suffix.json'],
        contains('"revision":5'),
      );
    },
  );

  test('v2 settings use guarded CAS without library JSON writes', () async {
    ActiveStorageNamespace.activate(StorageNamespace.account('account-v2'));
    final files = <String, String>{
      'app_prefs.json': '{"darkMode":true}',
      'library_folders.json': '{"folders":["Local"]}',
    };
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async => files[key] = value;
    final remote = <String, dynamic>{};
    final paths = <String>[];
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.method == 'GET' &&
            request.url.path == '/v2/account-settings') {
          return http.Response(jsonEncode({'settings': remote}), 200);
        }
        if (request.method == 'PUT' &&
            request.url.path.startsWith('/v2/account-settings/')) {
          final category = request.url.pathSegments.last;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final next = {
            'revision': (remote[category]?['revision'] as int? ?? 0) + 1,
            'value': body['value'],
          };
          remote[category] = next;
          return http.Response(jsonEncode(next), 200);
        }
        fail('Unexpected v2 settings request: ${request.url.path}');
      }),
    )..setAccessToken('test-token');
    addTearDown(api.close);
    final session = AccountSessionController(api)
      ..mode = AccountDataMode.account
      ..userId = 'account-v2';
    addTearDown(session.dispose);
    final service = AccountSettingsSyncService(
      apiClient: api,
      session: session,
    );
    await service.syncNow();
    expect(remote['appPreferences']['value'], {'darkMode': true});
    expect(paths, everyElement(startsWith('/v2/account-settings')));
    expect(paths, isNot(contains('/v2/account-settings/libraryState')));
    expect(files['library_folders.json'], '{"folders":["Local"]}');
  });

  test('v2 download retains an edit made during preimport backup', () async {
    const user = 'account-v2-settings-race';
    ActiveStorageNamespace.activate(StorageNamespace.account(user));
    final files = <String, String>{'app_prefs.json': '{"darkMode":false}'};
    var injected = false;
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async {
      files[key] = value;
      if (key.startsWith('account_preimport_') && !injected) {
        injected = true;
        files['app_prefs.json'] = '{"darkMode":true,"uiScale":1.5}';
      }
    };
    var remote = <String, dynamic>{
      'revision': 7,
      'value': {'darkMode': false, 'uiScale': 1.0},
    };
    final expectedRevisions = <int>[];
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/v2/account-settings') {
          return http.Response(
            jsonEncode({
              'settings': {'appPreferences': remote},
            }),
            200,
          );
        }
        if (request.method == 'PUT' &&
            request.url.path == '/v2/account-settings/appPreferences') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final revision = remote['revision'] as int;
          expect(body['expectedRevision'], revision);
          expectedRevisions.add(revision);
          remote = {'revision': revision + 1, 'value': body['value']};
          return http.Response(jsonEncode(remote), 200);
        }
        fail('Unexpected settings request: ${request.method} ${request.url}');
      }),
    )..setAccessToken('test-token');
    addTearDown(api.close);
    final session = AccountSessionController(api)
      ..mode = AccountDataMode.account
      ..userId = user;
    addTearDown(session.dispose);
    final sync = AccountSettingsSyncService(apiClient: api, session: session);

    await sync.syncNow();
    expect(injected, isTrue);
    expect(jsonDecode(files['app_prefs.json']!)['uiScale'], 1.5);
    expect(expectedRevisions, isEmpty);
    await sync.syncNow();
    expect(expectedRevisions, [7]);
    expect(remote['revision'], 8);
    expect((remote['value'] as Map)['darkMode'], true);
    expect((remote['value'] as Map)['uiScale'], 1.5);
  });

  test('v2 backup respects account namespace changes', () async {
    ActiveStorageNamespace.activate(StorageNamespace.account('account-a'));
    final files = <String, String>{'app_prefs.json': '{"darkMode":false}'};
    final preimportRead = Completer<void>();
    final releaseRead = Completer<String?>();
    textStorageReadOverride = (key) async {
      if (key.startsWith('account_preimport_')) {
        if (!preimportRead.isCompleted) {
          preimportRead.complete();
        }
        return releaseRead.future;
      }
      return files[key];
    };
    textStorageWriteOverride = (key, value) async {
      files[key] = value;
    };
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v2/account-settings');
        return http.Response(
          jsonEncode({
            'settings': {
              'appPreferences': {
                'revision': 3,
                'value': {'darkMode': true},
              },
            },
          }),
          200,
        );
      }),
    )..setAccessToken('test-token');
    addTearDown(api.close);
    final session = AccountSessionController(api)
      ..mode = AccountDataMode.account
      ..userId = 'account-a';
    addTearDown(session.dispose);
    final sync = AccountSettingsSyncService(apiClient: api, session: session);

    final pending = sync.syncNow();
    await preimportRead.future;
    sync.stop();
    session.userId = 'account-b';
    ActiveStorageNamespace.activate(StorageNamespace.account('account-b'));
    releaseRead.complete(null);
    await pending;
    expect(files['app_prefs.json'], '{"darkMode":false}');
    expect(
      files.keys.where((key) => key.startsWith('account_preimport_')),
      isEmpty,
    );
    expect(files.keys.where((key) => key.contains('cursor')), isEmpty);
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
    ActiveStorageNamespace.activate(StorageNamespace.local());
  });

  test('stopped v2 sync cannot write after an account switch', () async {
    ActiveStorageNamespace.activate(StorageNamespace.account('account-a'));
    final files = <String, String>{};
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, content) async => files[key] = content;
    final delayed = Completer<http.Response>();
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) => delayed.future),
    )..setAccessToken('test-token');
    addTearDown(api.close);
    final session = AccountSessionController(api)
      ..mode = AccountDataMode.account
      ..userId = 'account-a';
    addTearDown(session.dispose);
    final sync = AccountSettingsSyncService(apiClient: api, session: session);
    final pending = sync.syncNow();
    await Future<void>.delayed(Duration.zero);
    sync.stop();
    session.userId = 'account-b';
    ActiveStorageNamespace.activate(StorageNamespace.account('account-b'));
    delayed.complete(
      http.Response(
        jsonEncode({
          'settings': {
            'appPreferences': {
              'revision': 1,
              'value': {'darkMode': true},
            },
          },
        }),
        200,
      ),
    );
    await pending;
    expect(files.containsKey('app_prefs.json'), isFalse);
    expect(files.keys.where((key) => key.contains('cursor')), isEmpty);
  });
}
