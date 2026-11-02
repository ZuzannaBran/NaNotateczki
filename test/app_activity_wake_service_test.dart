import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/app_activity_wake_service.dart';

void main() {
  test('mouse hover is not deliberate activity but click and drag are', () {
    expect(
      AppActivityWakeService.isIntentionalPointer(const PointerHoverEvent()),
      isFalse,
    );
    expect(
      AppActivityWakeService.isIntentionalPointer(
        const PointerMoveEvent(buttons: 0),
      ),
      isFalse,
    );
    expect(
      AppActivityWakeService.isIntentionalPointer(
        const PointerMoveEvent(buttons: kPrimaryButton),
      ),
      isTrue,
    );
    expect(
      AppActivityWakeService.isIntentionalPointer(const PointerDownEvent()),
      isTrue,
    );
    expect(
      AppActivityWakeService.isIntentionalPointer(const PointerScrollEvent()),
      isTrue,
    );
  });

  test('pings at start, then only on activity after 30 minutes', () async {
    var now = DateTime.utc(2026, 11, 2, 10);
    final requests = <http.Request>[];
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{"status":"ok"}', 200);
      }),
    );
    final wake = AppActivityWakeService(apiClient: api, now: () => now);

    wake.noteActivity();
    await Future<void>.delayed(Duration.zero);
    expect(requests, isEmpty);

    wake.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(1));
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/health');
    expect(requests.single.headers.containsKey('authorization'), isFalse);

    now = now.add(const Duration(minutes: 29));
    for (var i = 0; i < 100; i++) {
      wake.noteActivity();
    }
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(1));

    now = now.add(const Duration(minutes: 1));
    wake.noteActivity();
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(2));

    now = now.add(const Duration(hours: 2));
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(2));

    wake.noteActivity();
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(3));

    wake.dispose();
    now = now.add(const Duration(hours: 1));
    wake.noteActivity();
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(3));
    api.close();
  });

  test('background and local-only mode do not trigger network calls', () async {
    var now = DateTime.utc(2026, 11, 2, 10);
    var requests = 0;
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('{"status":"ok"}', 200);
      }),
    );
    final wake = AppActivityWakeService(apiClient: api, now: () => now);

    wake.setForeground(false);
    wake.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 0);

    wake.setForeground(true);
    wake.noteActivity();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);

    wake.setEnabled(false);
    now = now.add(const Duration(hours: 1));
    wake.noteActivity();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);

    wake.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 2);
    api.close();
  });

  test('a failing wake request does not generate repeated retries', () async {
    var now = DateTime.utc(2026, 11, 2, 10);
    var requests = 0;
    final api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient((_) async {
        requests++;
        throw StateError('server is sleeping');
      }),
    );
    final wake = AppActivityWakeService(apiClient: api, now: () => now);

    wake.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(minutes: 1));
    wake.noteActivity();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);

    now = now.add(const Duration(minutes: 29));
    wake.noteActivity();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 2);
    wake.dispose();
    api.close();
  });
}
