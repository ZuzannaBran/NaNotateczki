import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/features/editor/presentation/contact_creator_tab.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('contact form sends a manual report without an account', (
    tester,
  ) async {
    Map<String, dynamic>? sent;
    final api = ApiClient(
      baseUri: Uri.parse('http://localhost:18080'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/reports/feedback');
        expect(request.headers['authorization'], isNull);
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{"reportId":"ok"}', 201);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: api,
        child: const MaterialApp(home: Scaffold(body: ContactCreatorTab())),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('contact-issue')),
      'The editor freezes when opening a notebook.',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('contact-send')));
    await tester.tap(find.byKey(const ValueKey('contact-send')));
    await tester.pumpAndSettle();

    expect(sent?['issue'], 'The editor freezes when opening a notebook.');
    expect(sent?['system'], isNotEmpty);
  });
}
