import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Cloudflare share deep links serve index without redirecting away', () {
    final rules = File('web/_redirects')
        .readAsLinesSync()
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'));
    expect(rules, contains('/share/* / 200'));
    expect(rules, isNot(contains('/share/* /index.html 200')));
    expect(rules, isNot(contains('/share/* / 302')));
  });
}
