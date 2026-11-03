import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/device_clock_check.dart';

void main() {
  final deviceTime = DateTime.utc(2026, 11, 3, 12);

  ApiClient apiFor(DateTime serverTime) {
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/time');
        expect(request.headers.containsKey('Authorization'), isFalse);
        return http.Response(
          jsonEncode({
            'serverTimeMs': serverTime.millisecondsSinceEpoch,
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    return api;
  }

  test('correct device time produces no warning', () async {
    final check = DeviceClockCheck(
      apiClient: apiFor(deviceTime),
      clock: () => deviceTime,
    );
    final difference = await check.measure();
    expect(difference, isNotNull);
    expect(difference!.isSignificant, isFalse);
  });

  test('device clock behind by two minutes triggers a warning', () async {
    final check = DeviceClockCheck(
      apiClient: apiFor(deviceTime.add(const Duration(minutes: 2))),
      clock: () => deviceTime,
    );
    final difference = await check.measure();
    expect(difference, isNotNull);
    expect(difference!.isSignificant, isTrue);
    expect(difference.offset.inSeconds, greaterThan(100));
  });

  test('device clock ahead by two minutes triggers a warning', () async {
    final check = DeviceClockCheck(
      apiClient: apiFor(deviceTime.subtract(const Duration(minutes: 2))),
      clock: () => deviceTime,
    );
    final difference = await check.measure();
    expect(difference, isNotNull);
    expect(difference!.isSignificant, isTrue);
    expect(difference.offset.inSeconds, lessThan(-100));
  });

  test('small drift remains within network-tolerant threshold', () async {
    final check = DeviceClockCheck(
      apiClient: apiFor(deviceTime.add(const Duration(seconds: 30))),
      clock: () => deviceTime,
    );
    expect((await check.measure())!.isSignificant, isFalse);
  });

  test('malformed clock response is rejected', () async {
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient(
        (_) async => http.Response('{"serverTimeMs":"invalid"}', 200),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      DeviceClockCheck(apiClient: api).measure(),
      throwsFormatException,
    );
  });
}
