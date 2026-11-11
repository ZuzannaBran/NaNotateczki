import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_text_sequence.dart';

const firstId = '00000000-0000-4000-8000-000000000001';
const secondId = '00000000-0000-4000-8000-000000000002';
const thirdId = '00000000-0000-4000-8000-000000000003';

OperationEnvelope textOperation({
  required String operationId,
  required String actorId,
  required OperationKind kind,
  required Map<String, dynamic> payload,
  int logicalClock = 10,
}) {
  return OperationEnvelope(
    operationId: operationId,
    actorId: actorId,
    actorSeq: 1,
    documentId: 'document',
    pageId: 'page',
    objectId: 'text',
    kind: kind,
    payload: payload,
    dependencies: const [],
    logicalClock: logicalClock,
  );
}

void main() {
  test('concurrent inserts converge in both delivery orders', () {
    final alice = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'A'},
        ],
      },
    );
    final bob = textOperation(
      operationId: secondId,
      actorId: 'bob',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': secondId, 'text': 'B'},
        ],
      },
    );
    final ab = OperationTextSequence.apply(
      OperationTextSequence.apply({}, alice),
      bob,
    );
    final ba = OperationTextSequence.apply(
      OperationTextSequence.apply({}, bob),
      alice,
    );
    expect(ab, ba);
    expect(OperationTextSequence.render(ab), 'BA');
  });

  test('insertion at caret precedes the existing successor', () {
    final original = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      logicalClock: 4,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'A'},
          {'id': secondId, 'text': 'B'},
        ],
      },
    );
    final atCaret = textOperation(
      operationId: thirdId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      logicalClock: 5,
      payload: {
        'afterAtomId': firstId,
        'atoms': [
          {'id': thirdId, 'text': 'X'},
        ],
      },
    );
    final state = OperationTextSequence.apply(
      OperationTextSequence.apply({}, original),
      atCaret,
    );
    expect(OperationTextSequence.render(state), 'AXB');
  });

  test('deleted atoms stay as anchors for delayed insertions', () {
    final insert = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'a'},
        ],
      },
    );
    final delete = textOperation(
      operationId: secondId,
      actorId: 'alice',
      kind: OperationKind.textDelete,
      payload: {
        'atomIds': [firstId],
      },
    );
    final follow = textOperation(
      operationId: thirdId,
      actorId: 'bob',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': firstId,
        'atoms': [
          {'id': thirdId, 'text': 'b'},
        ],
      },
    );
    final state = OperationTextSequence.apply(
      OperationTextSequence.apply(
        OperationTextSequence.apply({}, insert),
        delete,
      ),
      follow,
    );
    expect(OperationTextSequence.render(state), 'b');
    expect(OperationTextSequence.anchorBefore(state, 1), thirdId);
    expect((state[firstId] as Map)['deleted'], isTrue);
  });

  test('invalid atom never mutates prior projection', () {
    final insert = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'ok'},
        ],
      },
    );
    final before = OperationTextSequence.apply({}, insert);
    final duplicate = textOperation(
      operationId: secondId,
      actorId: 'bob',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'bad'},
        ],
      },
    );
    expect(
      () => OperationTextSequence.apply(before, duplicate),
      throwsFormatException,
    );
    expect(OperationTextSequence.render(before), 'ok');
  });

  test('validates text operations before they reach the outbox', () {
    final insert = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'a'},
        ],
      },
    );
    expect(insert.validateForV2Projection, returnsNormally);
    final invalid = textOperation(
      operationId: secondId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'x'},
          {'id': firstId, 'text': 'y'},
        ],
      },
    );
    expect(invalid.validateForV2Projection, throwsFormatException);
  });
  test('delete is copy-on-write and rejects corrupt singleton rank', () {
    final insert = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'A'},
          {'id': secondId, 'text': 'B'},
        ],
      },
    );
    final initial = OperationTextSequence.apply({}, insert);
    final removal = textOperation(
      operationId: thirdId,
      actorId: 'alice',
      kind: OperationKind.textDelete,
      payload: {
        'atomIds': [firstId],
      },
    );
    final updated = OperationTextSequence.apply(initial, removal);
    expect(OperationTextSequence.render(initial), 'AB');
    expect(OperationTextSequence.render(updated), 'B');
    expect(identical(initial[firstId], updated[firstId]), isFalse);
    expect(identical(initial[secondId], updated[secondId]), isTrue);
    final corrupt = {
      firstId: {
        'after': null,
        'text': 'A',
        'deleted': false,
        'order': [1, 'alice', 1, 'operation', 'broken'],
      },
    };
    expect(
      () => OperationTextSequence.visibleIds(corrupt),
      throwsFormatException,
    );
  });
  test('Quill embeds remain atomic during rendering and formatting', () {
    final inserted = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'A'},
          {
            'id': secondId,
            'text': '\uFFFC',
            'embed': {'image': 'asset:photo-1'},
          },
          {'id': thirdId, 'text': 'B'},
        ],
      },
    );
    final state = OperationTextSequence.apply({}, inserted);
    expect(OperationTextSequence.render(state), 'A\uFFFCB');
    expect(OperationTextSequence.renderDelta(state), [
      {'insert': 'A'},
      {
        'insert': {'image': 'asset:photo-1'},
      },
      {'insert': 'B'},
    ]);
    final formatted = OperationTextSequence.apply(
      state,
      textOperation(
        operationId: secondId,
        actorId: 'bob',
        kind: OperationKind.textFormat,
        payload: {
          'atomIds': [secondId],
          'attributes': {'width': 120},
        },
        logicalClock: 12,
      ),
    );
    expect(OperationTextSequence.renderDelta(formatted)[1], {
      'insert': {'image': 'asset:photo-1'},
      'attributes': {'width': 120},
    });
    expect(OperationTextSequence.renderDelta(state)[1], {
      'insert': {'image': 'asset:photo-1'},
    });
  });

  test('concurrent Quill formatting converges and keeps unrelated keys', () {
    final original = textOperation(
      operationId: firstId,
      actorId: 'origin',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'X'},
        ],
      },
    );
    final initial = OperationTextSequence.apply({}, original);
    final bold = textOperation(
      operationId: secondId,
      actorId: 'alice',
      kind: OperationKind.textFormat,
      logicalClock: 15,
      payload: {
        'atomIds': [firstId],
        'attributes': {'bold': true, 'color': 'red'},
      },
    );
    final color = textOperation(
      operationId: thirdId,
      actorId: 'zed',
      kind: OperationKind.textFormat,
      logicalClock: 15,
      payload: {
        'atomIds': [firstId],
        'attributes': {'color': 'blue'},
      },
    );
    final forward = OperationTextSequence.apply(
      OperationTextSequence.apply(initial, bold),
      color,
    );
    final reverse = OperationTextSequence.apply(
      OperationTextSequence.apply(initial, color),
      bold,
    );
    expect(forward, reverse);
    expect(OperationTextSequence.renderDelta(forward), [
      {
        'insert': 'X',
        'attributes': {'bold': true, 'color': 'blue'},
      },
    ]);
    expect(OperationTextSequence.render(initial), 'X');
  });
  test('corrupt Quill attribute precedence cannot be silently repaired', () {
    final original = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {
            'id': firstId,
            'text': 'A',
            'attributes': {'bold': true},
          },
        ],
      },
    );
    final initial = OperationTextSequence.apply({}, original);
    final malformed = <String, dynamic>{
      for (final entry in initial.entries)
        entry.key: {
          ...Map<String, dynamic>.from(entry.value as Map),
          'attributeVersions': {
            'bold': [10, {}, 1, firstId],
          },
        },
    };
    final format = textOperation(
      operationId: secondId,
      actorId: 'alice',
      kind: OperationKind.textFormat,
      logicalClock: 12,
      payload: {
        'atomIds': [firstId],
        'attributes': {'bold': false},
      },
    );
    expect(
      () => OperationTextSequence.render(malformed),
      throwsFormatException,
    );
    expect(
      () => OperationTextSequence.apply(malformed, format),
      throwsFormatException,
    );
    expect(OperationTextSequence.render(initial), 'A');
  });

  test('corrupt Quill precedence also blocks unrelated text insertion', () {
    final original = textOperation(
      operationId: firstId,
      actorId: 'alice',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {
            'id': firstId,
            'text': 'A',
            'attributes': {'bold': true},
          },
        ],
      },
    );
    final state = OperationTextSequence.apply({}, original);
    final corruptAtom = Map<String, dynamic>.from(state[firstId] as Map);
    corruptAtom['attributeVersions'] = {
      'bold': [true, 'alice', 1, firstId],
    };
    final malformed = <String, dynamic>{firstId: corruptAtom};
    final another = textOperation(
      operationId: secondId,
      actorId: 'bob',
      kind: OperationKind.textInsert,
      logicalClock: 11,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': secondId, 'text': 'B'},
        ],
      },
    );
    expect(
      () => OperationTextSequence.visibleIds(malformed),
      throwsFormatException,
    );
    expect(
      () => OperationTextSequence.apply(malformed, another),
      throwsFormatException,
    );
    expect(OperationTextSequence.render(state), 'A');
  });

  test('overlapping format removal converges despite delivery order', () {
    final insertion = textOperation(
      operationId: firstId,
      actorId: 'source',
      kind: OperationKind.textInsert,
      logicalClock: 3,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {
            'id': firstId,
            'text': 'A',
            'attributes': {'bold': true, 'italic': true},
          },
        ],
      },
    );
    final initial = OperationTextSequence.apply({}, insertion);
    final lower = textOperation(
      operationId: secondId,
      actorId: 'alice',
      kind: OperationKind.textFormat,
      logicalClock: 5,
      payload: {
        'atomIds': [firstId],
        'attributes': {'bold': true},
      },
    );
    final higher = textOperation(
      operationId: thirdId,
      actorId: 'bob',
      kind: OperationKind.textFormat,
      logicalClock: 6,
      payload: {
        'atomIds': [firstId],
        'attributes': {'bold': null},
      },
    );
    final firstOrder = OperationTextSequence.apply(
      OperationTextSequence.apply(initial, lower),
      higher,
    );
    final reversed = OperationTextSequence.apply(
      OperationTextSequence.apply(initial, higher),
      lower,
    );
    expect(firstOrder, reversed);
    expect(OperationTextSequence.renderDelta(firstOrder), [
      {
        'insert': 'A',
        'attributes': {'italic': true},
      },
    ]);
    expect(OperationTextSequence.renderDelta(initial), [
      {
        'insert': 'A',
        'attributes': {'bold': true, 'italic': true},
      },
    ]);
  });

  test('concurrent same-atom format cannot alter prior atom map', () {
    final insert = textOperation(
      operationId: firstId,
      actorId: 'origin',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'A'},
        ],
      },
    );
    final initial = OperationTextSequence.apply({}, insert);
    final update = textOperation(
      operationId: secondId,
      actorId: 'newer',
      kind: OperationKind.textFormat,
      logicalClock: 30,
      payload: {
        'atomIds': [firstId],
        'attributes': {'color': 'blue'},
      },
    );
    final result = OperationTextSequence.apply(initial, update);
    expect(OperationTextSequence.render(initial), 'A');
    expect((initial[firstId] as Map)['attributes'], isEmpty);
    expect(OperationTextSequence.renderDelta(result), [
      {
        'insert': 'A',
        'attributes': {'color': 'blue'},
      },
    ]);
  });
  test('shared Dart Python Quill convergence contract', () {
    final insert = textOperation(
      operationId: firstId,
      actorId: 'origin',
      kind: OperationKind.textInsert,
      logicalClock: 10,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'X'},
        ],
      },
    );
    final red = textOperation(
      operationId: secondId,
      actorId: 'alice',
      kind: OperationKind.textFormat,
      logicalClock: 11,
      payload: {
        'atomIds': [firstId],
        'attributes': {'bold': true, 'color': 'red'},
      },
    );
    final blue = textOperation(
      operationId: thirdId,
      actorId: 'zed',
      kind: OperationKind.textFormat,
      logicalClock: 11,
      payload: {
        'atomIds': [firstId],
        'attributes': {'color': 'blue'},
      },
    );
    final original = OperationTextSequence.apply({}, insert);
    final left = OperationTextSequence.apply(
      OperationTextSequence.apply(original, red),
      blue,
    );
    final right = OperationTextSequence.apply(
      OperationTextSequence.apply(original, blue),
      red,
    );
    const expected = [
      {
        'insert': 'X',
        'attributes': {'bold': true, 'color': 'blue'},
      },
    ];
    expect(OperationTextSequence.renderDelta(left), expected);
    expect(OperationTextSequence.renderDelta(right), expected);
    final deleted = textOperation(
      operationId: secondId,
      actorId: 'alice',
      kind: OperationKind.textDelete,
      logicalClock: 20,
      payload: {
        'atomIds': [firstId],
      },
    );
    final append = textOperation(
      operationId: thirdId,
      actorId: 'zed',
      kind: OperationKind.textInsert,
      logicalClock: 21,
      payload: {
        'afterAtomId': firstId,
        'atoms': [
          {'id': thirdId, 'text': 'B'},
        ],
      },
    );
    final retained = OperationTextSequence.apply(
      OperationTextSequence.apply(original, deleted),
      append,
    );
    expect(OperationTextSequence.render(retained), 'B');
    expect(OperationTextSequence.renderDelta(retained), [
      {'insert': 'B'},
    ]);
    expect((retained[firstId] as Map)['deleted'], isTrue);
  });
  test('delete and concurrent format keep the same tombstoned atom', () {
    final insert = textOperation(
      operationId: firstId,
      actorId: 'origin',
      kind: OperationKind.textInsert,
      payload: {
        'afterAtomId': null,
        'atoms': [
          {'id': firstId, 'text': 'A'},
        ],
      },
    );
    final original = OperationTextSequence.apply({}, insert);
    final formatting = textOperation(
      operationId: secondId,
      actorId: 'formatting',
      kind: OperationKind.textFormat,
      logicalClock: 30,
      payload: {
        'atomIds': [firstId],
        'attributes': {'bold': true},
      },
    );
    final deletion = textOperation(
      operationId: thirdId,
      actorId: 'deletion',
      kind: OperationKind.textDelete,
      logicalClock: 31,
      payload: {
        'atomIds': [firstId],
      },
    );
    final left = OperationTextSequence.apply(
      OperationTextSequence.apply(original, formatting),
      deletion,
    );
    final right = OperationTextSequence.apply(
      OperationTextSequence.apply(original, deletion),
      formatting,
    );
    expect(left, right);
    expect(OperationTextSequence.render(left), isEmpty);
    expect((left[firstId] as Map)['deleted'], isTrue);
    expect((left[firstId] as Map)['attributes'], {'bold': true});
  });
}
