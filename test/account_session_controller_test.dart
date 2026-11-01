import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('persists a local display name without credentials', () async {
    final stored = <String, String>{};
    textStorageReadOverride = (key) async => stored[key];
    textStorageWriteOverride = (key, value) async => stored[key] = value;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final session = AccountSessionController(client);

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

    final restored = AccountSessionController(client);
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
      final session = AccountSessionController(client);
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

      final restored = AccountSessionController(client);
      await restored.loadProfile();
      expect(restored.preferredMode, AccountDataMode.account);
      expect(restored.lastAccountUsername, 'test_user');
      expect(restored.shouldShowStartupDialog, isTrue);
    },
  );

  test('late profile read does not notify a disposed controller', () async {
    final pending = Completer<String?>();
    textStorageReadOverride = (_) => pending.future;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async => http.Response('', 500)),
    );
    final session = AccountSessionController(client);
    final load = session.loadProfile();
    session.dispose();
    pending.complete(null);
    await load;
    client.close();
  });

  test('concurrent backup and Web refresh rotate the token only once', () async {
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
    final session = AccountSessionController(client);
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
    final session = AccountSessionController(client);
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
      final session = AccountSessionController(client);
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
        final username = (jsonDecode(request.body) as Map<String, dynamic>)['username'];
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
    final first = AccountSessionController(client);
    await first.loadProfile();
    await first.login('account_a', 'password');
    expect(
      jsonDecode(stored[AccountSessionController.profileStorageKey]!)
          ['boundUserId'],
      'user-a',
    );
    first.useLocalOnly();

    final restarted = AccountSessionController(client);
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
      if (key != AccountSessionController.profileStorageKey) return null;
      return jsonEncode({
        'version': 1,
        'lastAccountUsername': 'original_user',
      });
    };
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async {
        fail('No request should be made for a different user.');
      }),
    );
    final session = AccountSessionController(client);
    await session.loadProfile();
    await expectLater(
      session.login('other_user', 'password'),
      throwsA(isA<StateError>()),
    );
    session.dispose();
    client.close();
  });
}
