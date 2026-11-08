import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_text_sequence.dart';

String _id(int number) =>
    '00000000-0000-4000-8000-${number.toString().padLeft(12, '0')}';

OperationEnvelope _op(
  int number,
  OperationKind kind,
  Map<String, dynamic> payload, {
  String actor = 'device',
  int clock = 10,
}) => OperationEnvelope(
  operationId: _id(number),
  actorId: actor,
  actorSeq: 1,
  documentId: 'v2-platform-document',
  pageId: 'v2-platform-page',
  objectId: 'v2-platform-text',
  kind: kind,
  payload: payload,
  dependencies: const [],
  logicalClock: clock,
);

/// Runs the same v2 protocol checks on web and real device test runners.
void registerV2PlatformReplayChecks() {
  group('v2 replay platform contract', () {
    test('all six independent Quill insert/format orders converge', () {
      final initial = OperationTextSequence.apply(
        {},
        _op(
          10,
          OperationKind.textInsert,
          {
            'afterAtomId': null,
            'atoms': [
              {'id': _id(1), 'text': 'A'},
              {'id': _id(2), 'text': '\n'},
            ],
          },
          clock: 3,
        ),
      );
      final alpha = _op(
        11,
        OperationKind.textInsert,
        {
          'afterAtomId': _id(1),
          'atoms': [
            {'id': _id(3), 'text': 'x'},
          ],
        },
        actor: 'alpha',
        clock: 10,
      );
      final beta = _op(
        12,
        OperationKind.textInsert,
        {
          'afterAtomId': _id(1),
          'atoms': [
            {'id': _id(4), 'text': 'y'},
          ],
        },
        actor: 'beta',
        clock: 20,
      );
      final formatting = _op(
        13,
        OperationKind.textFormat,
        {
          'atomIds': [_id(1)],
          'attributes': {'bold': true},
        },
        actor: 'formatting',
        clock: 30,
      );
      final operations = [alpha, beta, formatting];
      const orders = [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
      ];
      Map<String, dynamic>? expected;
      for (final order in orders) {
        var state = initial;
        for (final index in order) {
          state = OperationTextSequence.apply(state, operations[index]);
        }
        expect(OperationTextSequence.render(state), 'Ayx\n');
        expect(OperationTextSequence.renderDelta(state), [
          {
            'insert': 'A',
            'attributes': {'bold': true},
          },
          {'insert': 'yx\n'},
        ]);
        if (expected == null) {
          expected = state;
        } else {
          expect(state, expected);
        }
      }
      expect(OperationTextSequence.render(initial), 'A\n');
    });

    test('tombstoned atom stays an anchor in both delivery orders', () {
      final initial = OperationTextSequence.apply(
        {},
        _op(
          20,
          OperationKind.textInsert,
          {
            'afterAtomId': null,
            'atoms': [
              {'id': _id(1), 'text': 'A'},
            ],
          },
        ),
      );
      final removal = _op(
        21,
        OperationKind.textDelete,
        {
          'atomIds': [_id(1)],
        },
      );
      final insertion = _op(
        22,
        OperationKind.textInsert,
        {
          'afterAtomId': _id(1),
          'atoms': [
            {'id': _id(2), 'text': 'B'},
          ],
        },
      );
      final first = OperationTextSequence.apply(
        OperationTextSequence.apply(initial, removal),
        insertion,
      );
      final second = OperationTextSequence.apply(
        OperationTextSequence.apply(initial, insertion),
        removal,
      );
      expect(first, second);
      expect(OperationTextSequence.render(first), 'B');
      expect((first[_id(1)] as Map)['deleted'], isTrue);
      expect(OperationTextSequence.anchorBefore(first, 1), _id(2));
      expect(OperationTextSequence.render(initial), 'A');
    });

    test('formatting ties preserve independent attributes', () {
      final initial = OperationTextSequence.apply(
        {},
        _op(
          30,
          OperationKind.textInsert,
          {
            'afterAtomId': null,
            'atoms': [
              {
                'id': _id(1),
                'text': 'Q',
                'attributes': {'italic': true, 'color': 'red'},
              },
            ],
          },
          clock: 2,
        ),
      );
      final alpha = _op(
        31,
        OperationKind.textFormat,
        {
          'atomIds': [_id(1)],
          'attributes': {'color': null, 'bold': true},
        },
        actor: 'alpha',
        clock: 30,
      );
      final zeta = _op(
        32,
        OperationKind.textFormat,
        {
          'atomIds': [_id(1)],
          'attributes': {'color': 'blue'},
        },
        actor: 'zeta',
        clock: 30,
      );
      final first = OperationTextSequence.apply(
        OperationTextSequence.apply(initial, alpha),
        zeta,
      );
      final second = OperationTextSequence.apply(
        OperationTextSequence.apply(initial, zeta),
        alpha,
      );
      expect(first, second);
      expect(OperationTextSequence.renderDelta(first), [
        {
          'insert': 'Q',
          'attributes': {'italic': true, 'color': 'blue', 'bold': true},
        },
      ]);
      expect(OperationTextSequence.renderDelta(initial), [
        {
          'insert': 'Q',
          'attributes': {'italic': true, 'color': 'red'},
        },
      ]);
    });

    test('external embeds and duplicate atom IDs fail closed', () {
      final initial = OperationTextSequence.apply(
        {},
        _op(
          40,
          OperationKind.textInsert,
          {
            'afterAtomId': null,
            'atoms': [
              {'id': _id(1), 'text': 'A'},
            ],
          },
        ),
      );
      final external = _op(
        41,
        OperationKind.textInsert,
        {
          'afterAtomId': _id(1),
          'atoms': [
            {
              'id': _id(3),
              'text': '\uFFFC',
              'embed': {'image': 'https://invalid.example/photo.png'},
            },
          ],
        },
      );
      final duplicate = _op(
        42,
        OperationKind.textInsert,
        {
          'afterAtomId': _id(1),
          'atoms': [
            {'id': _id(1), 'text': 'duplicate'},
          ],
        },
      );
      expect(
        () => OperationTextSequence.apply(initial, external),
        throwsFormatException,
      );
      expect(
        () => OperationTextSequence.apply(initial, duplicate),
        throwsFormatException,
      );
      final attached = _op(
        43,
        OperationKind.textInsert,
        {
          'afterAtomId': _id(1),
          'atoms': [
            {
              'id': _id(3),
              'text': '\uFFFC',
              'embed': {'pdf': 'asset:pdf-7'},
            },
          ],
        },
      );
      expect(OperationTextSequence.renderDelta(
        OperationTextSequence.apply(initial, attached),
      ), [
        {'insert': 'A'},
        {
          'insert': {'pdf': 'asset:pdf-7'},
        },
      ]);
      expect(OperationTextSequence.render(initial), 'A');
    });

    test('transport preserves Quill whitespace and UTF-8 operations', () {
      final source = _op(
        50,
        OperationKind.textInsert,
        {
          'afterAtomId': null,
          'atoms': [
            {'id': _id(1), 'text': 'One  \t\n\n'},
          ],
        },
      );
      final encoded = jsonDecode(jsonEncode(source.toJson()));
      final decoded = OperationEnvelope.fromJson(
        Map<String, dynamic>.from(encoded as Map),
      );
      expect(decoded.toJson(), source.toJson());
      final atoms = OperationTextSequence.apply({}, decoded);
      expect(OperationTextSequence.render(atoms), 'One  \t\n\n');
      expect(OperationTextSequence.renderDelta(atoms), [
        {'insert': 'One  \t\n\n'},
      ]);
      expect(
        OperationTextSequence.withoutQuillTerminalNewline(
          OperationTextSequence.render(atoms),
        ),
        'One  \t\n',
      );
    });

    test('invalid format target does not alter the existing projection', () {
      final initial = OperationTextSequence.apply(
        {},
        _op(
          60,
          OperationKind.textInsert,
          {
            'afterAtomId': null,
            'atoms': [
              {'id': _id(1), 'text': 'A'},
            ],
          },
        ),
      );
      final missing = _op(
        61,
        OperationKind.textFormat,
        {
          'atomIds': [_id(9)],
          'attributes': {'italic': true},
        },
      );
      expect(
        () => OperationTextSequence.apply(initial, missing),
        throwsFormatException,
      );
      expect(OperationTextSequence.render(initial), 'A');
      expect(OperationTextSequence.renderDelta(initial), [
        {'insert': 'A'},
      ]);
    });
  });
}
