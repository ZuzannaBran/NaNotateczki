import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/editor/state/quill_style_patch.dart';

void main() {
  test('color patch keeps embeds and unrelated per-run formatting', () {
    final source = jsonEncode([
      {
        'insert': 'A',
        'attributes': {'bold': true, 'link': 'https://example.test'},
      },
      {
        'insert': {'pdf': 'asset:original'},
      },
      {
        'insert': 'B',
        'attributes': {'italic': true, 'font': 'Georgia'},
      },
      {
        'insert': '\n',
        'attributes': {'align': 'center'},
      },
    ]);
    final result = patchQuillStyle(
      source,
      inlineChanges: {'color': '#abcdef'},
      paragraphChanges: const {},
    );
    expect(jsonDecode(result), [
      {
        'insert': 'A',
        'attributes': {
          'bold': true,
          'link': 'https://example.test',
          'color': '#abcdef',
        },
      },
      {
        'insert': {'pdf': 'asset:original'},
        'attributes': {'color': '#abcdef'},
      },
      {
        'insert': 'B',
        'attributes': {'italic': true, 'font': 'Georgia', 'color': '#abcdef'},
      },
      {
        'insert': '\n',
        'attributes': {'align': 'center'},
      },
    ]);
    expect(jsonDecode(source)[0]['attributes'].containsKey('color'), isFalse);
  });

  test('paragraph patch affects line breaks without changing inline runs', () {
    final result = patchQuillStyle(
      jsonEncode([
        {
          'insert': 'A\nB\n',
          'attributes': {'bold': true, 'align': 'center'},
        },
      ]),
      inlineChanges: const {},
      paragraphChanges: {'align': 'right'},
    );
    expect(jsonDecode(result), [
      {
        'insert': 'A',
        'attributes': {'bold': true, 'align': 'center'},
      },
      {
        'insert': '\n',
        'attributes': {'bold': true, 'align': 'right'},
      },
      {
        'insert': 'B',
        'attributes': {'bold': true, 'align': 'center'},
      },
      {
        'insert': '\n',
        'attributes': {'bold': true, 'align': 'right'},
      },
    ]);
  });

  test('clearing decorations merges equivalent runs into canonical Delta', () {
    final result = patchQuillStyle(
      jsonEncode([
        {
          'insert': 'A',
          'attributes': {'bold': true, 'font': 'Georgia', 'color': '#112233'},
        },
        {
          'insert': 'B',
          'attributes': {'italic': true, 'color': '#112233'},
        },
        {
          'insert': '\n',
          'attributes': {'align': 'center'},
        },
      ]),
      inlineChanges: {'bold': null, 'italic': null, 'font': null},
      paragraphChanges: {'align': null},
    );
    expect(jsonDecode(result), [
      {
        'insert': 'AB',
        'attributes': {'color': '#112233'},
      },
      {'insert': '\n'},
    ]);
  });

  test('no-op preserves canonical Unicode and repeated embed identities', () {
    final source = jsonEncode([
      {'insert': '🙂é\n'},
      {
        'insert': {'image': 'asset:shared'},
      },
      {
        'insert': {'image': 'asset:shared'},
      },
      {'insert': '\n'},
    ]);
    expect(
      patchQuillStyle(
        source,
        inlineChanges: const {},
        paragraphChanges: const {},
      ),
      source,
    );
  });

  test('malformed style input fails without a plain text fallback', () {
    for (final source in [
      '',
      '{}',
      '[{"retain":1}]',
      '[{"insert":12}]',
      '[{"insert":"A","attributes":[]}]',
    ]) {
      expect(
        () => patchQuillStyle(
          source,
          inlineChanges: {'bold': true},
          paragraphChanges: const {},
        ),
        throwsFormatException,
      );
    }
  });
}
