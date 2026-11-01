import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/sync/api_client.dart';

void main() {
  test('uses the production API by default for REST and WebSocket', () {
    const override = String.fromEnvironment('BACKEND_URL');
    final client = ApiClient();

    if (override.trim().isEmpty) {
      expect(client.baseUri.toString(), 'https://api.nanotateczki.pl');
      expect(
        client.resolve('/v1/auth/login').toString(),
        'https://api.nanotateczki.pl/v1/auth/login',
      );
      expect(
        client.realtimeUri().toString(),
        'wss://api.nanotateczki.pl/v1/realtime',
      );
    } else {
      expect(client.baseUri.toString(), override.trim());
    }
    expect(client.isConfigured, isTrue);
    client.close();
  });

  test('rejects plaintext or credential-bearing production URLs', () {
    expect(
      () => ApiClient(baseUri: Uri.parse('http://api.example.com')),
      throwsFormatException,
    );
    expect(
      () => ApiClient(baseUri: Uri.parse('https://user:pass@example.com')),
      throwsFormatException,
    );
    expect(
      () => ApiClient(baseUri: Uri.parse('https://api.example.com?token=x')),
      throwsFormatException,
    );
    expect(
      () => ApiClient(baseUri: Uri.parse('http://127.0.0.1:8000')),
      returnsNormally,
    );
  });

  test('adds a bearer token and a bounded request identifier', () async {
    late http.Request captured;
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );
    client.setAccessToken('short-lived-access-token');

    final response = await client.get('/v1/sync/bootstrap');

    expect(response.decodeJson(), {'ok': true});
    expect(
      captured.headers['authorization'],
      'Bearer short-lived-access-token',
    );
    expect(
      captured.headers['x-request-id'],
      matches(RegExp(r'^[0-9a-f-]{36}$')),
    );
  });

  test('keeps structured conflict data for lossless resolution', () async {
    final client = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'detail': {
              'uid': 'note-1',
              'revision': 3,
              'deleted': false,
              'notebook': {'uid': 'note-1'},
            },
          }),
          409,
        ),
      ),
    );
    client.setAccessToken('access');

    await expectLater(
      client.get('/v1/sync/changes'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'status', 409)
            .having(
              (error) => error.payload,
              'payload',
              containsPair('detail', isA<Map<String, dynamic>>()),
            ),
      ),
    );
  });
}
