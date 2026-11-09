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
  test('property register rejects specialized stage-2 operations', () {
    final register = OperationPropertyRegister();
    for (final kind in [
      OperationKind.objectMove,
      OperationKind.textFormat,
      OperationKind.assetAttach,
      OperationKind.assetDetach,
    ]) {
      final payload = switch (kind) {
        OperationKind.objectMove => <String, dynamic>{
          'toPageId': 'other-page',
          'sortIndex': 1,
        },
        OperationKind.textFormat => <String, dynamic>{
          'atomIds': [a1],
          'attributes': {'bold': true},
        },
        OperationKind.assetAttach => <String, dynamic>{
          'assetId': 'image',
          'sha256': List.filled(64, 'a').join(),
          'sizeBytes': 10,
          'mediaType': 'image/png',
        },
        OperationKind.assetDetach => <String, dynamic>{'assetId': 'image'},
        _ => throw StateError('Unexpected operation kind'),
      };
      expect(
        () => register.apply(
          op(
            id: a2,
            actor: 'user',
            sequence: 1,
            clock: 2,
            kind: kind,
            payload: payload,
          ),
        ),
        throwsUnsupportedError,
      );
    }
  });

  test('task register separates task fields and preserves deletes', () {
    final register = OperationPropertyRegister();
    OperationEnvelope task(
      String id,
      int sequence,
      OperationKind kind,
      Map<String, dynamic> payload,
    ) => OperationEnvelope(
      operationId: id,
      actorId: 'task-device',
      actorSeq: sequence,
      documentId: OperationEnvelope.libraryDocumentId,
      objectId: 'task-1',
      kind: kind,
      payload: payload,
      dependencies: const [],
      logicalClock: sequence,
    );

    final created = task(a1, 1, OperationKind.taskCreate, {
      'value': {'plannerUid': 'planner-1', 'title': 'Initial'},
    });
    register.apply(created);
    register.apply(
      task(a2, 2, OperationKind.taskSet, {
        'properties': {'title': 'Revised'},
      }),
    );
    register.apply(
      task(b1, 3, OperationKind.taskMove, {
        'properties': {'plannerUid': 'planner-2'},
      }),
    );
    expect(register.fieldsFor(created), {
      'plannerUid': 'planner-2',
      'title': 'Revised',
    });

    register.apply(task(b2, 4, OperationKind.taskDelete, const {}));
    expect(register.fieldsFor(created), isNull);
  });

  test('actor advances logical time and includes own predecessor', () {
    final actor = OperationActorClock(actorId: 'device-a');
    final first = actor.next(
      documentId: 'notebook',
      pageId: 'page',
      objectId: 'stroke',
      kind: OperationKind.strokeCreate,
      payload: {
        'value': {'color': 'blue'},
      },
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
      id: a2,
      actor: 'A',
      sequence: 2,
      clock: 2,
      dependencies: [a1],
    );
    final after = op(
      id: b1,
      actor: 'B',
      sequence: 1,
      clock: 3,
      dependencies: [a2],
    );
    expect(queue.ingest(after), isEmpty);
    expect(queue.ingest(second), isEmpty);
    expect(queue.pendingCount, 2);
    expect(queue.missingDependencies(after), [a2]);
    expect(queue.ingest(first).map((value) => value.operationId), [a1, a2, b1]);
    expect(queue.pendingCount, 0);
  });

  test('duplicate packet is idempotent but changed ID or actor fork fails', () {
    final queue = CausalOperationBuffer();
    final original = op(id: a1, actor: 'A', sequence: 1, clock: 1);
    expect(queue.ingest(original), [original]);
    expect(queue.ingest(original), isEmpty);
    expect(
      () => queue.ingest(
        op(
          id: a1,
          actor: 'A',
          sequence: 1,
          clock: 1,
          payload: {
            'properties': {'color': 'red'},
          },
        ),
      ),
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
      () => queue.ingest(
        op(id: b1, actor: 'B', sequence: 1, clock: 19, dependencies: [a1]),
      ),
      throwsA(isA<OperationOrderException>()),
    );
  });

  test('two devices converge under shuffled delivery and clock skew', () {
    final changes = <OperationEnvelope>[
      op(
        id: a1,
        actor: 'A',
        sequence: 1,
        clock: 1,
        kind: OperationKind.objectCreate,
        objectId: 'one',
        payload: {
          'value': {'color': 'blue', 'x': 0},
        },
      ),
      op(
        id: a2,
        actor: 'A',
        sequence: 2,
        clock: 2,
        objectId: 'one',
        payload: {
          'properties': {'x': 12},
        },
        dependencies: [a1],
      ),
      op(
        id: b1,
        actor: 'B',
        sequence: 1,
        clock: 2,
        objectId: 'one',
        payload: {
          'properties': {'color': 'red'},
        },
        dependencies: [a1],
      ),
      op(
        id: b2,
        actor: 'B',
        sequence: 2,
        clock: 3,
        objectId: 'two',
        kind: OperationKind.objectCreate,
        payload: {
          'value': {'color': 'green'},
        },
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
      expect(
        projection.fieldsFor(changes.first),
        original.fieldsFor(changes.first),
      );
      expect(
        projection.fieldsFor(changes.last),
        original.fieldsFor(changes.last),
      );
    }
    expect(original.fieldsFor(changes.first), {'color': 'red', 'x': 12});
  });

  test('deletion beats older and newer edits', () {
    final create = op(
      id: a1,
      actor: 'A',
      sequence: 1,
      clock: 1,
      kind: OperationKind.objectCreate,
      payload: {
        'value': {'x': 1},
      },
    );
    final edit = op(
      id: b1,
      actor: 'B',
      sequence: 1,
      clock: 4,
      payload: {
        'properties': {'x': 2},
      },
    );
    final deletion = op(
      id: a2,
      actor: 'A',
      sequence: 2,
      clock: 2,
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
      id: a1,
      actor: 'A',
      sequence: 1,
      clock: 1,
      kind: OperationKind.objectCreate,
      payload: {
        'value': {'x': 1},
      },
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
      id: b1,
      actor: 'B',
      sequence: 1,
      clock: 7,
      payload: {
        'properties': {'color': 'red'},
      },
    );
    expect(compareOperationPrecedence(first, second), lessThan(0));
    final projection = OperationPropertyRegister()
      ..apply(second)
      ..apply(first);
    expect(projection.fieldsFor(first)?['color'], 'red');
  });

  test('causal cycle is rejected before either operation can apply', () {
    final queue = CausalOperationBuffer();
    expect(
      queue.ingest(
        op(id: a1, actor: 'A', sequence: 1, clock: 2, dependencies: [b1]),
      ),
      isEmpty,
    );
    expect(
      () => queue.ingest(
        op(id: b1, actor: 'B', sequence: 1, clock: 2, dependencies: [a1]),
      ),
      throwsA(isA<OperationOrderException>()),
    );
    expect(queue.pendingCount, 1);
  });

  test('actor cannot omit its immediately previous operation dependency', () {
    final queue = CausalOperationBuffer();
    queue.ingest(op(id: a1, actor: 'A', sequence: 1, clock: 1));
    expect(
      () => queue.ingest(op(id: a2, actor: 'A', sequence: 2, clock: 2)),
      throwsA(isA<OperationOrderException>()),
    );
  });

  test('queue capacity and checkpoint reject invalid replays', () {
    final original = CausalOperationBuffer();
    original.ingest(op(id: a1, actor: 'A', sequence: 1, clock: 1));
    original.ingest(
      op(id: a2, actor: 'A', sequence: 2, clock: 2, dependencies: [a1]),
    );
    final checkpoint = OperationCheckpoint.fromJson(
      original.exportCheckpoint().toJson(),
    );
    final queue = CausalOperationBuffer.fromCheckpoint(
      checkpoint,
      maximumPending: 1,
    );
    expect(
      () => queue.ingest(op(id: b2, actor: 'A', sequence: 1, clock: 1)),
      throwsA(isA<OperationOrderException>()),
    );
    queue.ingest(op(id: b1, actor: 'A', sequence: 4, clock: 4));
    expect(
      () => queue.ingest(op(id: b2, actor: 'B', sequence: 2, clock: 4)),
      throwsA(isA<OperationOrderException>()),
    );
  });

  test('invalid buffered child does not swallow accepted parent', () {
    final queue = CausalOperationBuffer();
    final bad = op(
      id: b1,
      actor: 'B',
      sequence: 1,
      clock: 1,
      dependencies: [a1],
    );
    expect(queue.ingest(bad), isEmpty);
    final parent = op(id: a1, actor: 'A', sequence: 1, clock: 2);
    expect(queue.ingest(parent), [parent]);
    expect(queue.rejectedOperations, contains(b1));
    expect(queue.pendingCount, 0);
    final corrected = op(
      id: b2,
      actor: 'B',
      sequence: 1,
      clock: 3,
      dependencies: [a1],
    );
    expect(queue.ingest(corrected), [corrected]);
    expect(() => queue.ingest(bad), throwsA(isA<OperationOrderException>()));
  });

  test('invalid incoming operation leaves checkpoint unchanged', () {
    final queue = CausalOperationBuffer();
    queue.ingest(op(id: a1, actor: 'A', sequence: 1, clock: 7));
    final before = queue.exportCheckpoint().toJson();
    expect(
      () => queue.ingest(
        op(id: a2, actor: 'A', sequence: 2, clock: 7, dependencies: [a1]),
      ),
      throwsA(isA<OperationOrderException>()),
    );
    expect(queue.exportCheckpoint().toJson(), before);
    expect(queue.pendingCount, 0);
    expect(queue.rejectedOperations, isEmpty);
    expect(
      queue.ingest(
        op(id: a2, actor: 'A', sequence: 2, clock: 8, dependencies: [a1]),
      ),
      hasLength(1),
    );
  });

  test('checkpoint restores predecessor, clocks and exact deduplication', () {
    final queue = CausalOperationBuffer();
    final parent = op(id: a1, actor: 'A', sequence: 1, clock: 15);
    queue.ingest(parent);
    final restored = CausalOperationBuffer.fromCheckpoint(
      OperationCheckpoint.fromJson(queue.exportCheckpoint().toJson()),
    );
    expect(restored.ingest(parent), isEmpty);
    expect(
      () => restored.ingest(op(id: a2, actor: 'A', sequence: 2, clock: 16)),
      throwsA(isA<OperationOrderException>()),
    );
    expect(
      () => restored.ingest(
        op(id: a2, actor: 'A', sequence: 2, clock: 15, dependencies: [a1]),
      ),
      throwsA(isA<OperationOrderException>()),
    );
    expect(
      () => restored.ingest(
        op(id: b1, actor: 'B', sequence: 1, clock: 14, dependencies: [a1]),
      ),
      throwsA(isA<OperationOrderException>()),
    );
    expect(
      () => restored.ingest(
        op(
          id: a1,
          actor: 'A',
          sequence: 1,
          clock: 15,
          payload: {
            'properties': {'color': 'forged'},
          },
        ),
      ),
      throwsA(isA<OperationOrderException>()),
    );
    expect(
      restored.ingest(
        op(id: b1, actor: 'B', sequence: 1, clock: 16, dependencies: [a1]),
      ),
      hasLength(1),
    );
  });

  test('pending gap cannot be checkpointed as committed history', () {
    final queue = CausalOperationBuffer();
    queue.ingest(
      op(id: a2, actor: 'A', sequence: 2, clock: 2, dependencies: [a1]),
    );
    expect(
      () => queue.exportCheckpoint(),
      throwsA(isA<OperationOrderException>()),
    );
    expect(
      () => CausalOperationBuffer.fromCheckpoint(
        OperationCheckpoint(
          operations: [
            op(id: a2, actor: 'A', sequence: 2, clock: 2, dependencies: [a1]),
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('actor includes observed remote frontier in future edits', () {
    final actor = OperationActorClock(actorId: 'local');
    final remote = op(id: b1, actor: 'remote', sequence: 1, clock: 20);
    actor.observe(remote);
    final first = actor.next(
      documentId: 'notebook',
      pageId: 'page',
      objectId: 'stroke',
      kind: OperationKind.objectSet,
      payload: {
        'properties': {'x': 1},
      },
    );
    expect(first.dependencies, contains(remote.operationId));
    expect(first.logicalClock, 21);
    final restored = OperationActorClock.fromCheckpoint(actor.toCheckpoint());
    final second = restored.next(
      documentId: 'notebook',
      pageId: 'page',
      objectId: 'stroke',
      kind: OperationKind.objectSet,
      payload: {
        'properties': {'x': 2},
      },
    );
    expect(
      second.dependencies,
      containsAll([remote.operationId, first.operationId]),
    );
  });
  test('more than 256 independent causal parents survive restart', () {
    final clock = OperationActorClock(actorId: 'local');
    final ids = <String>[];
    for (var i = 0; i < 300; i++) {
      final id =
          '${i.toRadixString(16).padLeft(8, '0')}'
          '-1111-4111-8111-111111111111';
      ids.add(id);
      clock.observe(op(id: id, actor: 'remote-$i', sequence: 1, clock: 2));
    }
    final restored = OperationActorClock.fromCheckpoint(clock.toCheckpoint());
    final next = restored.next(
      documentId: 'notebook',
      pageId: 'page',
      objectId: 'stroke',
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'x': 1},
      },
    );
    expect(next.dependencies.length, ids.length);
    expect(next.dependencies.toSet(), ids.toSet());
    expect(
      OperationEnvelope.fromJson(next.toJson()).dependencies,
      next.dependencies,
    );
    expect(restored.actorSeq, 1);
  });

  test('oversized causal frontier cannot advance actor sequence', () {
    final clock = OperationActorClock(actorId: 'local');
    final count = OperationEnvelope.maxDependencyBytes ~/ 39 + 1;
    for (var i = 0; i < count; i++) {
      final id =
          '${i.toRadixString(16).padLeft(8, '0')}'
          '-1111-4111-8111-111111111111';
      clock.observe(op(id: id, actor: 'remote-$i', sequence: 1, clock: 2));
    }
    final before = clock.toCheckpoint();
    expect(
      () => clock.next(
        documentId: 'notebook',
        pageId: 'page',
        objectId: 'stroke',
        kind: OperationKind.objectSet,
        payload: const {
          'properties': {'x': 1},
        },
      ),
      throwsFormatException,
    );
    expect(clock.toCheckpoint(), before);
  });

  test('actor rejects checkpoint with a newer observed clock', () {
    final actor = OperationActorClock(actorId: 'local');
    actor.observe(op(id: b1, actor: 'remote', sequence: 1, clock: 8));
    final invalid = actor.toCheckpoint()..['logicalClock'] = 7;
    expect(
      () => OperationActorClock.fromCheckpoint(invalid),
      throwsFormatException,
    );
  });

  test('rejected IDs remain blocked after checkpoint restore', () {
    final queue = CausalOperationBuffer();
    queue.ingest(
      op(id: b1, actor: 'B', sequence: 1, clock: 1, dependencies: [a1]),
    );
    queue.ingest(op(id: a1, actor: 'A', sequence: 1, clock: 2));
    final restored = CausalOperationBuffer.fromCheckpoint(
      OperationCheckpoint.fromJson(queue.exportCheckpoint().toJson()),
    );
    expect(restored.rejectedOperations, contains(b1));
    expect(
      () => restored.ingest(
        op(id: b1, actor: 'B', sequence: 1, clock: 3, dependencies: [a1]),
      ),
      throwsA(isA<OperationOrderException>()),
    );
    expect(
      restored.ingest(
        op(id: b2, actor: 'B', sequence: 1, clock: 3, dependencies: [a1]),
      ),
      hasLength(1),
    );
  });

  test('actor document binding persists and forbids another document', () {
    final actor = OperationActorClock(actorId: 'local');
    final first = actor.next(
      documentId: 'notebook',
      kind: OperationKind.objectSet,
      pageId: 'page',
      objectId: 'stroke',
      payload: const {
        'properties': {'x': 1},
      },
    );
    final restored = OperationActorClock.fromCheckpoint(actor.toCheckpoint());
    expect(restored.documentId, 'notebook');
    expect(
      () => restored.next(
        documentId: 'private-document',
        kind: OperationKind.objectSet,
        pageId: 'page',
        objectId: 'stroke',
        payload: const {
          'properties': {'x': 2},
        },
      ),
      throwsFormatException,
    );
    restored.observe(
      OperationEnvelope(
        operationId: b1,
        actorId: 'foreign',
        actorSeq: 1,
        logicalClock: 20,
        documentId: 'private-document',
        pageId: 'page',
        objectId: 'stroke',
        kind: OperationKind.objectSet,
        payload: const {
          'properties': {'x': 3},
        },
        dependencies: const [],
      ),
    );
    final next = restored.next(
      documentId: 'notebook',
      kind: OperationKind.objectSet,
      pageId: 'page',
      objectId: 'stroke',
      payload: const {
        'properties': {'x': 4},
      },
    );
    expect(next.dependencies, [first.operationId]);
  });

  test('unscoped nonempty actor checkpoint cannot be restored', () {
    final actor = OperationActorClock(actorId: 'local');
    actor.next(
      documentId: 'notebook',
      kind: OperationKind.objectSet,
      pageId: 'page',
      objectId: 'stroke',
      payload: const {
        'properties': {'x': 1},
      },
    );
    final old = actor.toCheckpoint()..remove('documentId');
    expect(() => OperationActorClock.fromCheckpoint(old), throwsArgumentError);
  });

  test('causal buffer rejects cross-document actors and parents', () {
    final queue = CausalOperationBuffer();
    final first = op(id: a1, actor: 'A', sequence: 1, clock: 1);
    expect(queue.ingest(first), [first]);
    OperationEnvelope different(String id, String actor, int sequence) {
      return OperationEnvelope(
        operationId: id,
        actorId: actor,
        actorSeq: sequence,
        documentId: 'private-document',
        pageId: 'page',
        objectId: 'stroke',
        kind: OperationKind.objectSet,
        payload: const {
          'properties': {'x': 2},
        },
        dependencies: const [a1],
        logicalClock: 2,
      );
    }

    expect(
      () => queue.ingest(different(b1, 'B', 1)),
      throwsA(isA<OperationOrderException>()),
    );
    expect(
      () => queue.ingest(different(a2, 'A', 2)),
      throwsA(isA<OperationOrderException>()),
    );
    expect(queue.pendingCount, 0);
    expect(queue.actorSequences['A'], 1);
  });

  test('actor clock prunes frontiers covered by another observation', () {
    final clock = OperationActorClock(actorId: 'local');
    String? parent;
    for (var i = 0; i < 260; i++) {
      final id =
          '${(i + 1000).toRadixString(16).padLeft(8, '0')}'
          '-1111-4111-8111-111111111111';
      clock.observe(
        OperationEnvelope(
          operationId: id,
          actorId: 'remote-$i',
          actorSeq: 1,
          documentId: 'notebook',
          pageId: 'page',
          objectId: 'item',
          kind: OperationKind.objectSet,
          payload: const {
            'properties': {'x': 1},
          },
          dependencies: [if (parent != null) parent],
          logicalClock: i + 1,
        ),
      );
      parent = id;
    }
    final next = clock.next(
      documentId: 'notebook',
      pageId: 'page',
      objectId: 'item',
      kind: OperationKind.objectSet,
      payload: const {
        'properties': {'x': 2},
      },
    );
    expect(next.dependencies, [parent]);
    expect(next.logicalClock, 261);
  });
  test('shared Dart Python LWW undo and permanent tombstone contract', () {
    final initial = op(
      id: a1,
      actor: 'A',
      sequence: 1,
      clock: 10,
      payload: const {
        'properties': {'colorValue': 17, 'sortIndex': 3},
      },
    );
    final concurrent = op(
      id: b1,
      actor: 'B',
      sequence: 1,
      clock: 10,
      payload: const {
        'properties': {'colorValue': 34, 'sortIndex': 5},
      },
    );
    final inverse = op(
      id: a2,
      actor: 'A',
      sequence: 2,
      clock: 11,
      payload: const {
        'properties': {'colorValue': 51},
      },
      dependencies: const [a1],
    );
    final removal = op(
      id: b2,
      actor: 'B',
      sequence: 2,
      clock: 12,
      kind: OperationKind.objectDelete,
      payload: const {},
      dependencies: const [b1],
    );
    for (final order in [
      [initial, concurrent],
      [concurrent, initial],
    ]) {
      final register = OperationPropertyRegister();
      for (final operation in [...order, inverse]) {
        register.apply(operation);
      }
      expect(register.fieldsFor(initial), {'colorValue': 51, 'sortIndex': 5});
      register.apply(removal);
      register.apply(initial);
      expect(register.fieldsFor(initial), isNull);
    }
  });
}
