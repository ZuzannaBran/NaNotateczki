import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_ordering.dart';
import 'package:program/data/sync/operation_protocol.dart';

const a1 = '11111111-1111-4111-8111-111111111111';
const a2 = '22222222-2222-4222-8222-222222222222';
const b1 = '33333333-3333-4333-8333-333333333333';
const b2 = '44444444-4444-4444-8444-444444444444';

OperationEnvelope op({
  required String id,
  required String actor,
  required int sequence,
  required int clock,
  OperationKind kind = OperationKind.objectSet,
  String objectId = 'stroke',
  Map<String, dynamic> payload = const {
    'properties': {'color': 'blue'},
  },
  List<String> dependencies = const [],
}) => OperationEnvelope(
  operationId: id,
  actorId: actor,
  actorSeq: sequence,
  documentId: 'notebook',
  pageId: 'page',
  objectId: objectId,
  kind: kind,
  payload: payload,
  dependencies: dependencies,
  logicalClock: clock,
);

void main() {
  test('actor advances logical time and includes own predecessor', () {
    final actor = OperationActorClock(actorId: 'device-a');
    final first = actor.next(
      documentId: 'notebook',
      pageId: 'page',
      objectId: 'stroke',
      kind: OperationKind.strokeCreate,
      payload: {'value': {'color': 'blue'}},
    );
    actor.observe(op(id: b1, actor: 'other', sequence: 1, clock: 900));
    final second = actor.next(
      documentId: 'notebook',
      pageId: 'page',
      objectId: 'stroke',
      kind: OperationKind.objectDelete,
    );
    expect(first.actorSeq, 1);
    expect(second.actorSeq, 2);
    expect(second.logicalClock, 901);
    expect(second.dependencies, contains(first.operationId));
    final restored = OperationActorClock.fromCheckpoint(actor.toCheckpoint());
    expect(restored.actorSeq, 2);
    expect(restored.previousOperationId, second.operationId);
  });

  test('missing actor predecessor and cross-actor dependency are buffered', () {
    final queue = CausalOperationBuffer();
    final first = op(id: a1, actor: 'A', sequence: 1, clock: 1);
    final second = op(
      id: a2, actor: 'A', sequence: 2, clock: 2,
      dependencies: [a1],
    );
    final after = op(
      id: b1, actor: 'B', sequence: 1, clock: 3,
      dependencies: [a2],
    );
    expect(queue.ingest(after), isEmpty);
    expect(queue.ingest(second), isEmpty);
    expect(queue.pendingCount, 2);
    expect(queue.missingDependencies(after), [a2]);
    expect(queue.ingest(first).map((value) => value.operationId),
        [a1, a2, b1]);
    expect(queue.pendingCount, 0);
  });

  test('duplicate packet is idempotent but changed ID or actor fork fails', () {
    final queue = CausalOperationBuffer();
    final original = op(id: a1, actor: 'A', sequence: 1, clock: 1);
    expect(queue.ingest(original), [original]);
    expect(queue.ingest(original), isEmpty);
    expect(
      () => queue.ingest(op(
        id: a1, actor: 'A', sequence: 1, clock: 1,
        payload: {'properties': {'color': 'red'}},
      )),
      throwsA(isA<OperationOrderException>()),
    );
    expect(
      () => queue.ingest(op(id: b1, actor: 'A', sequence: 1, clock: 1)),
      throwsA(isA<OperationOrderException>()),
    );
    final pending = CausalOperationBuffer();
    pending.ingest(op(id: a2, actor: 'A', sequence: 2, clock: 2));
    expect(
      () => pending.ingest(op(id: b2, actor: 'A', sequence: 2, clock: 2)),
      throwsA(isA<OperationOrderException>()),
    );
  });

  test('invalid causal clock cannot be used to reorder a known dependency', () {
    final queue = CausalOperationBuffer();
    queue.ingest(op(id: a1, actor: 'A', sequence: 1, clock: 20));
    expect(
      () => queue.ingest(op(
        id: b1, actor: 'B', sequence: 1, clock: 19,
        dependencies: [a1],
      )),
      throwsA(isA<OperationOrderException>()),
    );
  });

  test('two devices converge under shuffled delivery and clock skew', () {
    final changes = <OperationEnvelope>[
      op(
        id: a1, actor: 'A', sequence: 1, clock: 1,
        kind: OperationKind.objectCreate,
        objectId: 'one',
        payload: {'value': {'color': 'blue', 'x': 0}},
      ),
      op(
        id: a2, actor: 'A', sequence: 2, clock: 2,
        objectId: 'one',
        payload: {'properties': {'x': 12}},
        dependencies: [a1],
      ),
      op(
        id: b1, actor: 'B', sequence: 1, clock: 2,
        objectId: 'one',
        payload: {'properties': {'color': 'red'}},
        dependencies: [a1],
      ),
      op(
        id: b2, actor: 'B', sequence: 2, clock: 3,
        objectId: 'two',
        kind: OperationKind.objectCreate,
        payload: {'value': {'color': 'green'}},
        dependencies: [b1],
      ),
    ];
    final original = OperationPropertyRegister();
    for (final operation in changes) {
      original.apply(operation);
    }
    for (var seed = 0; seed < 25; seed++) {
      final queue = CausalOperationBuffer();
      final projection = OperationPropertyRegister();
      final shuffled = [...changes]..shuffle(Random(seed));
      for (final incoming in shuffled) {
        for (final accepted in queue.ingest(incoming)) {
          projection.apply(accepted);
        }
      }
      expect(queue.pendingCount, 0);
      expect(projection.fieldsFor(changes.first),
          original.fieldsFor(changes.first));
      expect(projection.fieldsFor(changes.last),
          original.fieldsFor(changes.last));
    }
    expect(original.fieldsFor(changes.first),
        {'color': 'red', 'x': 12});
  });

  test('deletion beats older and newer edits', () {
    final create = op(
      id: a1, actor: 'A', sequence: 1, clock: 1,
      kind: OperationKind.objectCreate,
      payload: {'value': {'x': 1}},
    );
    final edit = op(
      id: b1, actor: 'B', sequence: 1, clock: 4,
      payload: {'properties': {'x': 2}},
    );
    final deletion = op(
      id: a2, actor: 'A', sequence: 2, clock: 2,
      kind: OperationKind.objectDelete,
      payload: {},
      dependencies: [a1],
    );
    final register = OperationPropertyRegister();
    register.apply(deletion);
    register.apply(edit);
    register.apply(create);
    expect(register.fieldsFor(create), isNull);
  });

  test('later page or document tombstone hides child objects', () {
    final create = op(
      id: a1, actor: 'A', sequence: 1, clock: 1,
      kind: OperationKind.objectCreate,
      payload: {'value': {'x': 1}},
    );
    final pageDelete = OperationEnvelope(
      operationId: a2,
      actorId: 'A',
      actorSeq: 2,
      documentId: 'notebook',
      objectId: 'page',
      kind: OperationKind.pageDelete,
      payload: {},
      dependencies: [a1],
      logicalClock: 2,
    );
    final register = OperationPropertyRegister()..apply(create);
    register.apply(pageDelete);
    expect(register.fieldsFor(create), isNull);
  });

  test('tie break is stable without wall clock', () {
    final first = op(id: a1, actor: 'A', sequence: 1, clock: 7);
    final second = op(
      id: b1, actor: 'B', sequence: 1, clock: 7,
      payload: {'properties': {'color': 'red'}},
    );
    expect(compareOperationPrecedence(first, second), lessThan(0));
    final projection = OperationPropertyRegister()
      ..apply(second)
      ..apply(first);
    expect(projection.fieldsFor(first)?['color'], 'red');
  });

  test('queue capacity and checkpoint reject invalid replays', () {
    final queue = CausalOperationBuffer(
      initialActorSequences: {'A': 2},
      maximumPending: 1,
    );
    expect(
      () => queue.ingest(op(id: a1, actor: 'A', sequence: 1, clock: 1)),
      throwsA(isA<OperationOrderException>()),
    );
    queue.ingest(op(id: a2, actor: 'A', sequence: 4, clock: 4));
    expect(
      () => queue.ingest(op(id: b2, actor: 'B', sequence: 2, clock: 4)),
      throwsA(isA<OperationOrderException>()),
    );
  });
}
