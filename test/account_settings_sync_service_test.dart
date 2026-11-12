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
      useV2: true,
    );
    await service.syncNow();
    expect(remote['appPreferences']['value'], {'darkMode': true});
    expect(paths, everyElement(startsWith('/v2/account-settings')));
    expect(paths, isNot(contains('/v2/account-settings/libraryState')));
    expect(files['library_folders.json'], '{"folders":["Local"]}');
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
    final sync = AccountSettingsSyncService(
      apiClient: api,
      session: session,
      useV2: true,
    );
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

  test(
    'account settings transfer across devices with safe revisions',
    () async {
      final remote = <String, Map<String, dynamic>>{};
      var writes = 0;

      ApiClient buildClient() => ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/v1/account-settings') {
            return http.Response(jsonEncode({'settings': remote}), 200);
          }
          if (request.method == 'PUT' &&
              request.url.path.startsWith('/v1/account-settings/')) {
            final category = request.url.pathSegments.last;
            final payload = jsonDecode(request.body) as Map<String, dynamic>;
            final current = remote[category];
            final revision = current?['revision'] as int? ?? 0;
            if (payload['expectedRevision'] != revision) {
              return http.Response(
                jsonEncode({
                  'detail': {'revision': revision, 'value': current?['value']},
                }),
                409,
              );
            }
            writes++;
            final value = payload['value'];
            remote[category] = {'revision': revision + 1, 'value': value};
            return http.Response(jsonEncode(remote[category]), 200);
          }
          fail('Unexpected request: ${request.url}');
        }),
      )..setAccessToken('valid');

      final firstFiles = <String, String>{
        'app_prefs.json': '{"darkMode":true,"uiScale":1.25}',
        'shared_recent_colors.json': '[4278190080]',
        'editor_prefs.json': '{"penSize":3}',
      };
      textStorageReadOverride = (key) async => firstFiles[key];
      textStorageWriteOverride = (key, value) async => firstFiles[key] = value;
      final firstClient = buildClient();
      addTearDown(firstClient.close);
      final firstSession = AccountSessionController(firstClient)
        ..mode = AccountDataMode.account
        ..userId = 'account-a';
      addTearDown(firstSession.dispose);
      final first = AccountSettingsSyncService(
        apiClient: firstClient,
        session: firstSession,
      );
      await first.syncNow();
      expect(writes, 3);
      expect(remote['appPreferences']!['value']['darkMode'], true);

      final secondFiles = <String, String>{};
      textStorageReadOverride = (key) async => secondFiles[key];
      textStorageWriteOverride = (key, value) async => secondFiles[key] = value;
      final secondClient = buildClient();
      addTearDown(secondClient.close);
      final secondSession = AccountSessionController(secondClient)
        ..mode = AccountDataMode.account
        ..userId = 'account-a';
      addTearDown(secondSession.dispose);
      var remoteApplied = 0;
      final second = AccountSettingsSyncService(
        apiClient: secondClient,
        session: secondSession,
        onRemoteApplied: () async {
          remoteApplied++;
        },
      );
      await second.syncNow();
      expect(remoteApplied, 1);
      expect(jsonDecode(secondFiles['app_prefs.json']!)['darkMode'], true);
      expect(jsonDecode(secondFiles['shared_recent_colors.json']!), [
        4278190080,
      ]);
      expect(writes, 3);

      secondFiles['app_prefs.json'] = '{"darkMode":false,"uiScale":1.25}';
      await second.syncNow();
      expect(remote['appPreferences']!['revision'], 2);
      expect(remote['appPreferences']!['value']['darkMode'], false);
    },
  );

  test(
    'an edit during library upload remains local and syncs next pass',
    () async {
      final suffix = sha256
          .convert(utf8.encode('account-a'))
          .toString()
          .substring(0, 16);
      final files = <String, String>{
        'library_folders.json': jsonEncode({
          'folders': ['Local'],
          'covers': {},
          'plannerTasks': {},
          'recentCoverColors': [],
        }),
        'account_settings_cursor_$suffix.json': jsonEncode({
          'version': 1,
          'settings': {
            'libraryState': {
              'revision': 0,
              'value': {
                'folders': <String>[],
                'covers': {},
                'plannerTasks': {},
                'recentCoverColors': <int>[],
              },
            },
          },
        }),
      };
      textStorageReadOverride = (key) async => files[key];
      textStorageWriteOverride = (key, value) async => files[key] = value;
      var remoteRevision = 1;
      Map<String, dynamic> remoteValue = {
        'folders': ['Remote'],
        'covers': {},
        'plannerTasks': {},
        'recentCoverColors': [],
      };
      var puts = 0;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'settings': {
                  'libraryState': {
                    'revision': remoteRevision,
                    'value': remoteValue,
                  },
                },
              }),
              200,
            );
          }
          expect(request.url.path, '/v1/account-settings/libraryState');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['expectedRevision'], remoteRevision);
          puts++;
          if (puts == 1) {
            // The editor changes the local file while REST is in flight.
            files['library_folders.json'] = jsonEncode({
              'folders': ['Local', 'During upload'],
              'covers': {},
              'plannerTasks': {},
              'recentCoverColors': [],
            });
          }
          remoteRevision++;
          remoteValue = Map<String, dynamic>.from(
            body['value'] as Map<String, dynamic>,
          );
          return http.Response(
            jsonEncode({'revision': remoteRevision, 'value': remoteValue}),
            200,
          );
        }),
      )..setAccessToken('token');
      addTearDown(client.close);
      final session = AccountSessionController(client)
        ..mode = AccountDataMode.account
        ..userId = 'account-a';
      addTearDown(session.dispose);
      final sync = AccountSettingsSyncService(
        apiClient: client,
        session: session,
      );

      await sync.syncNow();
      final afterFirst =
          jsonDecode(files['library_folders.json']!) as Map<String, dynamic>;
      expect(afterFirst['folders'], contains('During upload'));
      expect(afterFirst['folders'], contains('Remote'));

      await sync.syncNow();
      expect(puts, 2);
      expect(remoteValue['folders'], ['During upload', 'Local', 'Remote']);
    },
  );

  test('existing account deletion beats an unbound local folder', () async {
    final files = <String, String>{
      'library_folders.json': jsonEncode({
        'folders': ['Already deleted'],
        'covers': {
          'Already deleted': {'color': 7},
        },
        'plannerTasks': {},
        'recentCoverColors': <int>[],
      }),
    };
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async => files[key] = value;
    var uploads = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.method == 'PUT') {
          uploads++;
          fail('An old local folder must not be uploaded.');
        }
        return http.Response(
          jsonEncode({
            'settings': {
              'libraryState': {
                'revision': 7,
                'value': {
                  'folders': <String>[],
                  'covers': {},
                  'plannerTasks': {},
                  'recentCoverColors': <int>[],
                },
              },
            },
          }),
          200,
        );
      }),
    )..setAccessToken('token');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-a';
    addTearDown(session.dispose);
    final sync = AccountSettingsSyncService(
      apiClient: client,
      session: session,
    );

    await sync.syncNow();
    expect(uploads, 0);
    expect(
      (jsonDecode(files['library_folders.json']!) as Map)['folders'],
      isEmpty,
    );
    expect(
      files.keys.any((key) => key.startsWith('account_preimport_')),
      isTrue,
    );
  });

  test('expired access token is refreshed without signing out', () async {
    textStorageReadOverride = (_) async => null;
    textStorageWriteOverride = (_, _) async {};
    var calls = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        calls++;
        if (request.headers['authorization'] != 'Bearer renewed') {
          return http.Response('{"detail":"Expired token"}', 401);
        }
        return http.Response('{"settings":{}}', 200);
      }),
    )..setAccessToken('expired');
    addTearDown(client.close);
    final session = _RefreshingSession(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-a';
    addTearDown(session.dispose);
    final sync = AccountSettingsSyncService(
      apiClient: client,
      session: session,
    );

    await sync.syncNow();
    expect(session.refreshCalls, 1);
    expect(session.isSignedIn, isTrue);
    expect(calls, 2);
    expect(sync.lastError, isNull);
  });

  test('accepted update survives a lost client response', () async {
    final stored = <String, String>{'app_prefs.json': '{"darkMode":true}'};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    var serverRevision = 0;
    Object? serverValue;
    var writes = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'settings': {
                if (serverRevision > 0)
                  'appPreferences': {
                    'revision': serverRevision,
                    'value': serverValue,
                  },
              },
            }),
            200,
          );
        }
        writes++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        serverValue = body['value'];
        serverRevision++;
        return http.Response(
          jsonEncode({'revision': serverRevision, 'value': serverValue}),
          200,
        );
      }),
    )..setAccessToken('valid');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-a';
    addTearDown(session.dispose);
    final sync = AccountSettingsSyncService(
      apiClient: client,
      session: session,
    );
    await sync.syncNow();
    expect(writes, 1);
    stored['app_prefs.json'] = '{"darkMode":false}';
    serverRevision = 2;
    serverValue = {'darkMode': false};
    await sync.syncNow();
    expect(writes, 1);
    await sync.syncNow();
    expect(writes, 1);
  });

  test('simultaneous edits never silently overwrite another device', () async {
    final files = <String, String>{'app_prefs.json': '{"darkMode":true}'};
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async => files[key] = value;
    var remoteRevision = 1;
    var remoteDarkMode = true;
    var writes = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'settings': {
                'appPreferences': {
                  'revision': remoteRevision,
                  'value': {
                    'darkMode': remoteDarkMode,
                    if (remoteRevision > 1) 'uiScale': 1.25,
                  },
                },
              },
            }),
            200,
          );
        }
        writes++;
        return http.Response('', 409);
      }),
    )..setAccessToken('valid');
    addTearDown(client.close);
    final session = AccountSessionController(client)
      ..mode = AccountDataMode.account
      ..userId = 'account-a';
    addTearDown(session.dispose);
    final sync = AccountSettingsSyncService(
      apiClient: client,
      session: session,
    );
    await sync.syncNow();
    files['app_prefs.json'] = '{"darkMode":false}';
    remoteRevision = 2;
    remoteDarkMode = true;
    await expectLater(sync.syncNow(), throwsA(isA<StateError>()));
    expect(writes, 0);
    expect(jsonDecode(files['app_prefs.json']!)['darkMode'], false);
  });
}

class _RefreshingSession extends AccountSessionController {
  _RefreshingSession(super.apiClient);

  int refreshCalls = 0;

  @override
  Future<void> refresh() async {
    refreshCalls++;
    apiClient.setAccessToken('renewed');
  }
}
