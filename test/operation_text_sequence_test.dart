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
}
