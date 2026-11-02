import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/sync/account_credential_store.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryAccountCredentialStore credentials;
  setUp(() {
    credentials = _MemoryAccountCredentialStore();
  });

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('sends account-start signal before remote session restore', () async {
    final events = <String>[];
    textStorageReadOverride = (key) async {
      if (key != AccountSessionController.profileStorageKey) {
        return null;
      }
      return jsonEncode({
        'version': 1,
        'onboardingComplete': true,
        'preferredMode': 'account',
        'boundUserId': 'user-1',
        'lastAccountUsername': 'test_user',
      });
    };
    credentials.value = jsonEncode({
      'version': 1,
      'backend': 'https://api.example.com',
      'userId': 'user-1',
      'username': 'test_user',
      'refreshToken': 'stored-refresh-token',
    });
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        events.add('refresh');
        return http.Response('{"detail":"unavailable"}', 503);
      }),
    );
    final session = AccountSessionController(
      client,
      credentialStore: credentials,
      onBeforeAccountRestore: () => events.add('wake'),
    );
    await session.loadProfile();
    expect(events, ['wake', 'refresh']);
    expect(session.profileLoaded, isTrue);
    session.dispose();
    client.close();
  });

  test('persists a local display name without credentials', () async {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final session = AccountSessionController(
      client,
      credentialStore: credentials,
    );

    await session.loadProfile();
    expect(session.shouldShowStartupDialog, isTrue);
    await session.useLocalProfile('  Zuzanna  ');

    expect(session.displayName, 'Zuzanna');
    expect(session.avatarLetter, 'Z');
    expect(session.preferredMode, AccountDataMode.localOnly);
    expect(session.shouldShowStartupDialog, isFalse);
    final encoded = stored[AccountSessionController.profileStorageKey]!;
    expect(encoded, isNot(contains('password')));
    expect(encoded, isNot(contains('token')));

    final restored = AccountSessionController(
      client,
      credentialStore: credentials,
    );
    await restored.loadProfile();
    expect(restored.displayName, 'Zuzanna');
    expect(restored.isLocalProfile, isTrue);
    expect(restored.shouldShowStartupDialog, isFalse);
  });

  test(
    'uses the server change-password contract and keeps tokens in memory',
    () async {
      final stored = <String, String>{};
      textStorageReadOverride = (key) async => stored[key];
      textStorageWriteOverride = (key, value) async => stored[key] = value;
      Map<String, dynamic>? passwordRequest;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/register') {
            return http.Response(
              jsonEncode({
                'accessToken': 'access-secret',
                'refreshToken': 'refresh-token-with-at-least-forty-characters',
                'expiresIn': 600,
                'userId': 'user-1',
                'username': 'test_user',
              }),
              201,
            );
          }
          if (request.url.path == '/v1/auth/change-password') {
            expect(request.method, 'POST');
            expect(request.headers['authorization'], 'Bearer access-secret');
            passwordRequest = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('', 204);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      final session = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await session.loadProfile();

      await session.register('TEST_USER', 'first-secure-password');
      await session.changePassword(
        'first-secure-password',
        'second-secure-password',
      );

      expect(passwordRequest, {
        'currentPassword': 'first-secure-password',
        'newPassword': 'second-secure-password',
      });
      expect(session.isSignedIn, isTrue);
      expect(session.preferredMode, AccountDataMode.account);
      final encoded = stored[AccountSessionController.profileStorageKey]!;
      expect(encoded, contains('test_user'));
      expect(encoded, isNot(contains('access-secret')));
      expect(encoded, isNot(contains('refresh-token')));
      expect(encoded, isNot(contains('secure-password')));
      expect(credentials.value, contains('refresh-token'));
      await session.requireAccountReauthentication();
      expect(credentials.value, isNull);
      expect(session.isSignedIn, isFalse);

      final restored = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await restored.loadProfile();
      expect(restored.preferredMode, AccountDataMode.account);
      expect(restored.lastAccountUsername, 'test_user');
      expect(restored.shouldShowStartupDialog, isFalse);
    },
  );

  test(
    'restores a rotating session after a restart and clears it at logout',
    () async {
      final profile = <String, String>{};
      textStorageReadOverride = (key) async => profile[key];
      textStorageWriteOverride = (key, value) async {
        profile[key] = value;
      };
      var refreshCalls = 0;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/login') {
            return http.Response(
              jsonEncode({
                'accessToken': 'access-1',
                'refreshToken': 'refresh-1',
                'expiresIn': 600,
                'userId': 'user-1',
                'username': 'test_user',
              }),
              200,
            );
          }
          if (request.url.path == '/v1/auth/refresh') {
            refreshCalls++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['refreshToken'], 'refresh-$refreshCalls');
            return http.Response(
              jsonEncode({
                'accessToken': 'access-${refreshCalls + 1}',
                'refreshToken': 'refresh-${refreshCalls + 1}',
                'expiresIn': 600,
                'userId': 'user-1',
                'username': 'test_user',
              }),
              200,
            );
          }
          if (request.url.path == '/v1/auth/logout') {
            return http.Response('', 204);
          }
          fail('Unexpected request: ${request.url}');
        }),
      );
      final initial = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await initial.loadProfile();
      await initial.login('test_user', 'password');
      expect(credentials.value, contains('refresh-1'));
      expect(
        profile[AccountSessionController.profileStorageKey],
        isNot(contains('refresh-1')),
      );

      final restarted = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await restarted.loadProfile();
      expect(restarted.isSignedIn, isTrue);
      expect(restarted.shouldShowStartupDialog, isFalse);
      expect(restarted.userId, 'user-1');
      expect(credentials.value, contains('refresh-2'));
      await restarted.refresh();
      expect(refreshCalls, 2);
      expect(credentials.value, contains('refresh-3'));

      await restarted.logout();
      expect(credentials.value, isNull);
      expect(restarted.isSignedIn, isFalse);
      initial.dispose();
      restarted.dispose();
      client.close();
    },
  );

  test(
    'offline restart keeps credentials but never forces onboarding',
    () async {
      final profile = <String, String>{};
      textStorageReadOverride = (key) async => profile[key];
      textStorageWriteOverride = (key, value) async {
        profile[key] = value;
      };
      var offline = false;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (offline) {
            throw StateError('Server unreachable');
          }
          return http.Response(
            jsonEncode({
              'accessToken': 'access',
              'refreshToken': 'refresh',
              'expiresIn': 600,
              'userId': 'user-1',
              'username': 'test_user',
            }),
            200,
          );
        }),
      );
      final initial = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await initial.loadProfile();
      await initial.login('test_user', 'password');
      offline = true;
      final restarted = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await restarted.loadProfile();
      expect(restarted.profileLoaded, isTrue);
      expect(restarted.isSignedIn, isFalse);
      expect(restarted.shouldShowStartupDialog, isFalse);
      expect(restarted.displayName, 'test_user');
      expect(credentials.value, contains('refresh'));
      initial.dispose();
      restarted.dispose();
      client.close();
    },
  );

  test(
    'revoked refresh token is deleted without a startup login dialog',
    () async {
      final profile = <String, String>{};
      textStorageReadOverride = (key) async => profile[key];
      textStorageWriteOverride = (key, value) async {
        profile[key] = value;
      };
      var revoke = false;
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (revoke) {
            return http.Response(
              jsonEncode({'detail': 'Session expired'}),
              401,
            );
          }
          return http.Response(
            jsonEncode({
              'accessToken': 'access',
              'refreshToken': 'refresh',
              'expiresIn': 600,
              'userId': 'user-1',
              'username': 'test_user',
            }),
            200,
          );
        }),
      );
      final initial = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await initial.loadProfile();
      await initial.login('test_user', 'password');
      revoke = true;
      final restarted = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await restarted.loadProfile();
      expect(restarted.shouldShowStartupDialog, isFalse);
      expect(restarted.isSignedIn, isFalse);
      expect(credentials.value, isNull);
      initial.dispose();
      restarted.dispose();
      client.close();
    },
  );

  test('late profile read does not notify a disposed controller', () async {
    final pending = Completer<String?>();
    textStorageReadOverride = (_) => pending.future;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final session = AccountSessionController(
      client,
      credentialStore: credentials,
    );
    final load = session.loadProfile();
    session.dispose();
    pending.complete(null);
    await load;
    client.close();
  });

  test('concurrent refresh requests rotate the token only once', () async {
    final responsePending = Completer<http.Response>();
    var refreshCalls = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/auth/login') {
          return http.Response(
            jsonEncode({
              'accessToken': 'old-access',
              'refreshToken': 'old-refresh',
              'expiresIn': 1,
              'userId': 'user-1',
              'username': 'test_user',
            }),
            200,
          );
        }
        if (request.url.path == '/v1/auth/refresh') {
          refreshCalls++;
          return responsePending.future;
        }
        fail('Unexpected authentication endpoint.');
      }),
    );
    final session = AccountSessionController(
      client,
      credentialStore: credentials,
    );
    await session.login('test_user', 'password');
    final first = session.refresh();
    final second = session.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(refreshCalls, 1);

    responsePending.complete(
      http.Response(
        jsonEncode({
          'accessToken': 'new-access',
          'refreshToken': 'new-refresh',
          'expiresIn': 600,
          'userId': 'user-1',
          'username': 'test_user',
        }),
        200,
      ),
    );
    await Future.wait([first, second]);
    expect(session.debugRefreshToken, 'new-refresh');
    expect(client.accessToken, 'new-access');
    session.dispose();
    client.close();
  });

  test('registers with eight characters and accepts legacy logins', () async {
    final requests = <String, Object?>{};
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        requests[request.url.path] =
            (jsonDecode(request.body) as Map<String, dynamic>)['password'];
        return http.Response(
          jsonEncode({
            'accessToken': 'access-token',
            'refreshToken': 'refresh-token',
            'expiresIn': 600,
            'userId': 'user-1',
            'username': 'test_user',
          }),
          request.url.path.endsWith('/register') ? 201 : 200,
        );
      }),
    );
    final session = AccountSessionController(
      client,
      credentialStore: credentials,
    );
    await session.register('test_user', '12345678');
    await session.login('test_user', 'short');
    expect(requests['/v1/auth/register'], '12345678');
    expect(requests['/v1/auth/login'], 'short');
    await expectLater(
      session.register('test_user', '1234567'),
      throwsA(isA<FormatException>()),
    );
    client.close();
  });

  test(
    'surfaces the server detail for an incorrect current password',
    () async {
      final client = ApiClient(
        baseUri: Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/login') {
            return http.Response(
              jsonEncode({
                'accessToken': 'access',
                'refreshToken': 'refresh-token-with-at-least-forty-characters',
                'expiresIn': 600,
                'userId': 'user-1',
                'username': 'test_user',
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({'detail': 'Current password is incorrect.'}),
            400,
          );
        }),
      );
      final session = AccountSessionController(
        client,
        credentialStore: credentials,
      );
      await session.login('test_user', 'first-secure-password');

      await expectLater(
        session.changePassword('wrong-password', 'second-secure-password'),
        throwsA(isA<ApiException>()),
      );

      expect(session.error, 'Current password is incorrect.');
    },
  );

  test('refuses a second account on the same local notebook storage', () async {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    var loginCalls = 0;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        loginCalls++;
        final username =
            (jsonDecode(request.body) as Map<String, dynamic>)['username'];
        return http.Response(
          jsonEncode({
            'accessToken': 'access-$username',
            'refreshToken': 'refresh-$username',
            'expiresIn': 600,
            'userId': username == 'account_a' ? 'user-a' : 'user-b',
            'username': username,
          }),
          200,
        );
      }),
    );
    final first = AccountSessionController(
      client,
      credentialStore: credentials,
    );
    await first.loadProfile();
    await first.login('account_a', 'password');
    expect(
      jsonDecode(
        stored[AccountSessionController.profileStorageKey]!,
      )['boundUserId'],
      'user-a',
    );
    first.useLocalOnly();

    final restarted = AccountSessionController(
      client,
      credentialStore: credentials,
    );
    await restarted.loadProfile();
    await expectLater(
      restarted.login('account_b', 'password'),
      throwsA(isA<StateError>()),
    );
    expect(loginCalls, 1);
    expect(restarted.isSignedIn, isFalse);
    await restarted.login('account_a', 'password');
    expect(restarted.isSignedIn, isTrue);
    expect(loginCalls, 2);
    first.dispose();
    restarted.dispose();
    client.close();
  });

  test('legacy account profile blocks a different username', () async {
    textStorageReadOverride = (key) async {
      if (key != AccountSessionController.profileStorageKey) {
        return null;
      }
      return jsonEncode({'version': 1, 'lastAccountUsername': 'original_user'});
    };
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async {
        fail('No request should be made for a different user.');
      }),
    );
    final session = AccountSessionController(
      client,
      credentialStore: credentials,
    );
    await session.loadProfile();
    await expectLater(
      session.login('other_user', 'password'),
      throwsA(isA<StateError>()),
    );
    session.dispose();
    client.close();
  });

  test('failed account binding persistence disables remote sessions', () async {
    textStorageReadOverride = (_) async => null;
    textStorageWriteOverride = (_, _) async {
      throw StateError('Disk is full.');
    };
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'accessToken': 'access',
            'refreshToken': 'refresh',
            'expiresIn': 600,
            'userId': 'user-a',
            'username': 'account_a',
          }),
          200,
        );
      }),
    );
    final session = AccountSessionController(
      client,
      credentialStore: credentials,
    );
    await session.loadProfile();
    await expectLater(
      session.login('account_a', 'password'),
      throwsA(isA<StateError>()),
    );
    expect(session.isSignedIn, isFalse);
    expect(client.accessToken, isNull);
    session.dispose();
    client.close();
  });
}

class _MemoryAccountCredentialStore implements AccountCredentialStore {
  String? value;
  int writes = 0;
  int deletes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String credential) async {
    value = credential;
    writes++;
  }

  @override
  Future<void> delete() async {
    value = null;
    deletes++;
  }
}
