import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/study_share_service.dart';

void main() {
  test(
    'guest joins v2 and reads appearance without a snapshot request',
    () async {
      final paths = <String>[];
      final api = ApiClient(
        baseUri: Uri.parse('https://example.test'),
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/appearance')) {
            expect(request.headers['authorization'], 'Bearer guest-ticket');
            return http.Response(
              jsonEncode({
                'appearance': {
                  'darkMode': true,
                  'backgroundStyle': 1,
                  'backgroundSpacing': 32,
                },
              }),
              200,
            );
          }
          expect(jsonDecode(request.body), {'password': 'x'});
          return http.Response(
            jsonEncode({
              'ticket': 'guest-ticket',
              'documentUid': 'doc',
              'protocol': 'v2',
              'title': 'V2',
              'revision': 0,
            }),
            200,
          );
        }),
      );
      final guest = StudyShareGuestClient(apiClient: api);
      addTearDown(guest.close);
      final joined = await guest.join('share', 'x');
      expect(joined['documentUid'], 'doc');
      expect(
        (await guest.appearance(
          'share',
          joined['ticket'] as String,
        ))?['darkMode'],
        true,
      );
      expect(guest.eventsUri('share').path, '/v2/study-shares/share/events');
      expect(paths, [
        '/v2/study-shares/share/join',
        '/v2/study-shares/share/appearance',
      ]);
    },
  );

  test('a legacy invitation cannot open a snapshot editor', () async {
    final guest = StudyShareGuestClient(
      apiClient: ApiClient(
        baseUri: Uri.parse('https://example.test'),
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'ticket': 'old',
              'title': 'Legacy',
              'revision': 1,
              'protocol': 'v1',
            }),
            200,
          ),
        ),
      ),
    );
    addTearDown(guest.close);
    await expectLater(guest.join('share', 'x'), throwsFormatException);
  });
}
