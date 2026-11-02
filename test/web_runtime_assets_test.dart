import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web startup uses bundled renderer and PDF resources', () {
    final index = File('web/index.html').readAsStringSync();
    expect(index, isNot(contains('cdn.jsdelivr.net')));
    final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();
    expect(bootstrap, contains('{{flutter_js}}'));
    expect(bootstrap, contains('{{flutter_build_config}}'));
    expect(bootstrap, contains('canvasKitBaseUrl:'));
    expect(bootstrap, contains('document.baseURI'));
    expect(bootstrap, contains('globalThis.pdfRenderOptions ='));
    expect(bootstrap, isNot(contains('https://')));
  });

  test('bundled PDF distribution retains all pinned files unchanged', () {
    const directory = 'web/vendor/pdfjs/4.6.82';
    final manifest =
        jsonDecode(File('$directory/SHA256SUMS.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(manifest.keys, containsAll(['pdf.min.mjs', 'pdf.worker.min.mjs']));
    expect(
      manifest.keys.where((path) => path.endsWith('.bcmap')),
      hasLength(168),
    );
    for (final entry in manifest.entries) {
      final file = File('$directory/${entry.key}');
      expect(file.existsSync(), isTrue, reason: entry.key);
      expect(
        sha256.convert(file.readAsBytesSync()).toString(),
        entry.value,
        reason: entry.key,
      );
    }
  });
}
