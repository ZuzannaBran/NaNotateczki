import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/operation_asset_gateway.dart';

void main() {
  const png = <int>[137, 80, 78, 71, 13, 10, 26, 10, 1];
  final digest = crypto.sha256.convert(png).toString();

  ApiClient clientFor(Future<http.Response> Function(http.Request) handler) {
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient(handler),
    );
    api.setAccessToken('owner-token');
    addTearDown(api.close);
    return api;
  }

  test('upload verifies digest, length and MIME before attach', () async {
    final gateway = OperationAssetGateway(clientFor((request) async {
      expect(request.method, 'PUT');
      expect(request.url.path, '/v2/assets/$digest');
      expect(request.bodyBytes, png);
      expect(request.headers['authorization'], 'Bearer owner-token');
      return http.Response(jsonEncode({
        'sha256': digest,
        'sizeBytes': png.length,
        'mediaType': 'image/png',
      }), 200);
    }));
    final payload = await gateway.upload(
      assetId: 'image-1', bytes: png, mediaType: 'image/png',
    );
    expect(payload, {
      'assetId': 'image-1',
      'sha256': digest,
      'sizeBytes': png.length,
      'mediaType': 'image/png',
    });
  });

  test('wrong server checksum prevents an asset attach', () async {
    final gateway = OperationAssetGateway(clientFor((_) async {
      return http.Response(jsonEncode({
        'sha256': List.filled(64, '0').join(),
        'sizeBytes': png.length,
        'mediaType': 'image/png',
      }), 200);
    }));
    await expectLater(gateway.upload(
      assetId: 'image-1', bytes: png, mediaType: 'image/png',
    ), throwsFormatException);
  });

  test('download verifies the bytes and rejects corruption', () async {
    var corrupt = false;
    final gateway = OperationAssetGateway(clientFor((_) async {
      return http.Response.bytes(corrupt ? <int>[1, 2] : png, 200);
    }));
    expect(await gateway.download(
      sha256: digest, sizeBytes: png.length,
    ), png);
    corrupt = true;
    await expectLater(gateway.download(
      sha256: digest, sizeBytes: png.length,
    ), throwsFormatException);
  });

  test('guest assets use share ticket and scoped header', () async {
    const ticket = '01234567890123456789012345678901234567890123456789';
    const shareId = '11111111-1111-4111-8111-111111111111';
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer $ticket');
        expect(request.headers['x-share-id'], shareId);
        return http.Response(jsonEncode({
          'sha256': digest,
          'sizeBytes': png.length,
          'mediaType': 'image/png',
        }), 200);
      }),
    );
    addTearDown(api.close);
    final gateway = OperationAssetGateway(
      api, shareId: shareId, guestTicket: ticket,
    );
    expect((await gateway.upload(
      assetId: 'image-1', bytes: png, mediaType: 'image/png',
    ))['sha256'], digest);
  });

  test('invalid size, MIME and ticket fail before request', () async {
    var called = false;
    final client = clientFor((_) async {
      called = true;
      return http.Response('{}', 200);
    });
    final gateway = OperationAssetGateway(client);
    await expectLater(gateway.upload(
      assetId: 'bad', bytes: [], mediaType: 'image/png',
    ), throwsArgumentError);
    await expectLater(gateway.upload(
      assetId: 'bad', bytes: png, mediaType: 'text/html',
    ), throwsArgumentError);
    expect(called, isFalse);
    expect(() => OperationAssetGateway(
      client, shareId: 'one',
    ), throwsArgumentError);
  });
}
