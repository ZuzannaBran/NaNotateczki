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
                'email': 'user@example.com',
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

      await session.register('USER@example.com', 'first-secure-password');
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
      expect(encoded, contains('user@example.com'));
      expect(encoded, isNot(contains('access-secret')));
      expect(encoded, isNot(contains('refresh-token')));
      expect(encoded, isNot(contains('secure-password')));

      final restored = AccountSessionController(client);
      await restored.loadProfile();
      expect(restored.preferredMode, AccountDataMode.account);
      expect(restored.lastAccountEmail, 'user@example.com');
      expect(restored.shouldShowStartupDialog, isTrue);
    },
  );

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
                'email': 'user@example.com',
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
      await session.login('user@example.com', 'first-secure-password');

      await expectLater(
        session.changePassword('wrong-password', 'second-secure-password'),
        throwsA(isA<ApiException>()),
      );

      expect(session.error, 'Current password is incorrect.');
    },
  );
}
