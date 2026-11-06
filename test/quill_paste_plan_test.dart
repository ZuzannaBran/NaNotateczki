import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill_delta_from_html/flutter_quill_delta_from_html.dart';
import 'package:program/features/editor/state/quill_paste_plan.dart';

String _uri(String mime, List<int> bytes) =>
    'data:$mime;base64,${base64Encode(bytes)}';

void main() {
  final files = <String, List<int>>{
    'image/png': [137, 80, 78, 71, 13, 10, 26, 10, 1],
    'image/jpeg': [255, 216, 255, 1],
    'image/webp': [82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80],
    'application/pdf': [37, 80, 68, 70, 45, 49],
  };
  test('HTML conversion keeps rich text and verifies embedded image bytes', () {
    final source = _uri('image/png', files['image/png']!);
    final converted = HtmlToDelta().convert(
      '<p><strong>Bold</strong> <em>italic</em><img src="$source"></p>',
    );
    final plan = QuillPastePlan.fromDelta(converted.toJson());
    final ready = plan.materialize((_, _) => 'asset:html-image');
    expect(
      ready.any((op) => (op['attributes'] as Map? ?? {})['bold'] == true),
      isTrue,
    );
    expect(
      ready.any((op) => (op['attributes'] as Map? ?? {})['italic'] == true),
      isTrue,
    );
    expect(ready.where((op) => op['insert'] is Map).single['insert'], {
      'image': 'asset:html-image',
    });
  });
  for (final entry in files.entries) {
    test(
      'inline ${entry.key} owns verified bytes without base64 expansion',
      () {
        final bytes = Uint8List.fromList(entry.value);
        final plan = QuillPastePlan.fromMediaBytes(bytes);
        bytes[bytes.length - 1] ^= 1;
        expect(plan.characterCount, 1);
        expect(plan.embedCount, 1);
        expect(plan.importedByteLength, entry.value.length);
        expect(plan.existingAssets, isEmpty);
        final ready = plan.materialize((actual, type) {
          expect(actual, entry.value);
          expect(type, entry.key == 'application/pdf' ? 'pdf' : 'image');
          return 'asset:picked-file';
        });
        expect(ready.single['insert'], {
          entry.key == 'application/pdf' ? 'pdf' : 'image': 'asset:picked-file',
        });
      },
    );
    test(
      'validates ${entry.key} data without staging before materialization',
      () {
        final type = entry.key == 'application/pdf' ? 'pdf' : 'image';
        final source = _uri(entry.key, entry.value);
        final plan = QuillPastePlan.fromDelta([
          {
            'insert': 'A',
            'attributes': {'bold': true},
          },
          {
            'insert': {type: source},
          },
          {
            'insert': {type: source},
          },
          {
            'insert': '\n',
            'attributes': {'align': 'center'},
          },
        ]);
        expect(plan.importedByteLength, entry.value.length);
        expect(plan.characterCount, 4);
        expect(plan.embedCount, 2);
        var prepared = 0;
        final result = plan.materialize((Uint8List bytes, String embedType) {
          prepared++;
          expect(bytes, entry.value);
          expect(embedType, type);
          return 'asset:new-inline';
        });
        expect(prepared, 1);
        expect(result, [
          {
            'insert': 'A',
            'attributes': {'bold': true},
          },
          {
            'insert': {type: 'asset:new-inline'},
          },
          {
            'insert': {type: 'asset:new-inline'},
          },
          {
            'insert': '\n',
            'attributes': {'align': 'center'},
          },
        ]);
      },
    );
  }

  test('inline file rejects empty, unsupported and oversized bytes', () {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([1, 2, 3]),
    ]) {
      expect(() => QuillPastePlan.fromMediaBytes(bytes), throwsFormatException);
    }
    expect(
      () => QuillPastePlan.fromMediaBytes(
        Uint8List.fromList(files['image/png']!),
        byteLimit: files['image/png']!.length - 1,
      ),
      throwsFormatException,
    );
    expect(
      () => QuillPastePlan.fromMediaBytes(Uint8List(0), byteLimit: 0),
      throwsArgumentError,
    );
  });

  test('canonical references require later document scope verification', () {
    final plan = QuillPastePlan.fromDelta([
      {
        'insert': {'pdf': 'asset:existing'},
      },
      {
        'insert': {'pdf': 'asset:existing'},
      },
    ]);
    expect(plan.existingAssets, {'existing': 'pdf'});
    expect(plan.importedByteLength, 0);
    final result = plan.materialize((_, _) => throw StateError('No new file'));
    expect(result.first['insert'], {'pdf': 'asset:existing'});
  });

  test('HTML conversion cannot bypass URI and byte validation', () {
    for (final source in [
      'https://example.test/image.png',
      'file:///tmp/image.png',
      _uri('image/png', files['application/pdf']!),
    ]) {
      final delta = HtmlToDelta().convert('<p><img src="$source"></p>');
      expect(
        () => QuillPastePlan.fromDelta(delta.toJson()),
        throwsFormatException,
      );
    }
  });

  test('untrusted URIs and mismatched types reject the whole paste', () {
    for (final source in [
      'https://example.test/image.png',
      'file:///tmp/image.png',
      _uri('image/png', files['application/pdf']!),
      _uri('image/svg+xml', [60, 115, 118, 103, 62]),
      'data:image/png;base64,not-valid-base64!',
    ]) {
      expect(
        () => QuillPastePlan.fromDelta([
          {
            'insert': {'image': _uri('image/png', files['image/png']!)},
          },
          {
            'insert': {'image': source},
          },
        ]),
        throwsFormatException,
      );
    }
    expect(
      () => QuillPastePlan.fromDelta([
        {
          'insert': {'pdf': _uri('image/png', files['image/png']!)},
        },
      ]),
      throwsFormatException,
    );
  });

  test('deduplicates bytes but enforces aggregate paste size', () {
    final first = _uri('image/png', files['image/png']!);
    final second = _uri('image/png', [...files['image/png']!, 2]);
    expect(
      () => QuillPastePlan.fromDelta([
        {
          'insert': {'image': first},
        },
        {
          'insert': {'image': second},
        },
      ], byteLimit: 9),
      throwsFormatException,
    );
    final plan = QuillPastePlan.fromDelta([
      {
        'insert': {'image': first},
      },
      {
        'insert': {'image': first},
      },
    ], byteLimit: 9);
    expect(plan.importedByteLength, 9);
  });

  test(
    'invalid operations, attributes and unlinked characters fail closed',
    () {
      for (final delta in <List<dynamic>>[
        [
          {'retain': 1},
        ],
        [
          {'insert': '\uFFFC'},
        ],
        [
          {
            'insert': {'video': 'https://example.test/video'},
          },
        ],
        [
          {
            'insert': 'A',
            'attributes': {'bold': []},
          },
        ],
        [
          {
            'insert': 'A',
            'attributes': {'size': double.nan},
          },
        ],
        [
          {
            'insert': {'image': 'asset:same'},
          },
          {
            'insert': {'pdf': 'asset:same'},
          },
        ],
      ]) {
        expect(() => QuillPastePlan.fromDelta(delta), throwsFormatException);
      }
    },
  );

  test(
    'text budget includes Unicode code points and rejects oversized text',
    () {
      expect(
        QuillPastePlan.fromDelta([
          {'insert': '🙂é'},
        ]).characterCount,
        3,
      );
      expect(
        () => QuillPastePlan.fromDelta([
          {'insert': 'A' * 50001},
        ]),
        throwsFormatException,
      );
    },
  );

  test('copies input attributes and checks materialized references', () {
    final attributes = <String, dynamic>{'bold': true};
    final plan = QuillPastePlan.fromDelta([
      {'insert': 'A', 'attributes': attributes},
      {
        'insert': {'image': _uri('image/png', files['image/png']!)},
      },
    ]);
    attributes['bold'] = false;
    expect(plan.materialize((_, _) => 'asset:safe').first['attributes'], {
      'bold': true,
    });
    expect(
      () => plan.materialize((_, _) => 'https://example.test/not-an-asset'),
      throwsFormatException,
    );
  });
}
