import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web startup uses bundled renderer and PDF resources', () {
    final index = File('web/index.html').readAsStringSync();
    expect(index, isNot(contains('cdn.jsdelivr.net')));
    final headers = File('web/_headers').readAsStringSync();
    expect(headers, contains('/*.mjs\n  Content-Type: text/javascript'));
    expect(headers, contains('/*.wasm\n  Content-Type: application/wasm'));
    final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();
    expect(bootstrap, contains('{{flutter_js}}'));
    expect(bootstrap, contains('{{flutter_build_config}}'));
    expect(bootstrap, contains('canvasKitBaseUrl:'));
    expect(bootstrap, contains('fontFallbackBaseUrl:'));
    expect(bootstrap, contains('document.baseURI'));
    expect(bootstrap, contains('globalThis.pdfRenderOptions ='));
    expect(bootstrap, isNot(contains('https://')));
  });

  test(
    'all engine fallback fonts are bundled without changing their bytes',
    () {
      const directory = 'web/vendor/flutter-fonts';
      final manifest =
          jsonDecode(File('$directory/manifest.json').readAsStringSync())
              as Map<String, dynamic>;
      final files = manifest['files'] as Map<String, dynamic>;
      expect(files, hasLength(725));
      expect(files.keys.any((path) => path.startsWith('roboto/')), isTrue);
      expect(
        files.keys.any((path) => path.startsWith('notocoloremoji/')),
        isTrue,
      );
      expect(files.keys.any((path) => path.startsWith('notosansjp/')), isTrue);
      for (final entry in files.entries) {
        final bytes = File('$directory/${entry.key}').readAsBytesSync();
        expect(ascii.decode(bytes.take(4).toList()), 'wOF2', reason: entry.key);
        expect(
          sha256.convert(bytes).toString(),
          entry.value,
          reason: entry.key,
        );
      }
    },
  );

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
