import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/share_operation_projection.dart';

String id(int value) =>
    '00000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

OperationEnvelope op(
  int number,
  OperationKind kind,
  Map<String, dynamic> payload, {
  String? pageId,
  String? objectId,
  String actor = 'a',
  int clock = 1,
}) => OperationEnvelope(
  operationId: id(number),
  actorId: actor,
  actorSeq: number,
  documentId: 'doc',
  pageId: pageId,
  objectId: objectId,
  kind: kind,
  payload: payload,
  dependencies: const [],
  logicalClock: clock,
);

ShareOperationProjection initial() {
  var state = ShareOperationProjection.empty();
  state = state.apply(
    op(1, OperationKind.documentCreate, {
      'value': {'title': 'Example'},
    }),
  );
  state = state.apply(
    op(2, OperationKind.pageCreate, {
      'value': {'title': 'Page'},
    }, objectId: 'page'),
  );
  state = state.apply(
    op(3, OperationKind.strokeCreate, {
      'value': {'color': 1, 'dx': 0},
    }, pageId: 'page', objectId: 'stroke'),
  );
  return state;
}

Map<String, dynamic> stroke(ShareOperationProjection state) {
  final pages = state.document!['pages'] as Map;
  final objects = (pages['page'] as Map)['objects'] as Map;
  return Map<String, dynamic>.from(objects['stroke'] as Map);
}

void main() {
  test('independent color and move converge without snapshot replacement', () {
    final color = op(
      4,
      OperationKind.objectSet,
      {
        'properties': {'color': 8},
      },
      pageId: 'page',
      objectId: 'stroke',
      actor: 'alice',
      clock: 5,
    );
    final move = op(
      5,
      OperationKind.objectTransform,
      {
        'properties': {'dx': 42},
      },
      pageId: 'page',
      objectId: 'stroke',
      actor: 'bob',
      clock: 5,
    );
    final left = initial().apply(color).apply(move);
    final right = initial().apply(move).apply(color);
    expect(left.document, right.document);
    expect((stroke(left)['properties'] as Map)['color'], 8);
    expect((stroke(left)['properties'] as Map)['dx'], 42);
  });

  test('remote deletion never resurrects an object or its old UID', () {
    final delete = op(
      6, OperationKind.objectDelete, {},
      pageId: 'page',
      objectId: 'stroke',
    );
    final edit = op(
      7, OperationKind.objectSet,
      {
        'properties': {'color': 99},
      },
      pageId: 'page',
      objectId: 'stroke',
    );
    final deleted = initial().apply(delete).apply(edit);
    final objects = ((deleted.document!['pages'] as Map)['page'] as Map)
        ['objects'] as Map;
    expect(objects, isEmpty);
    expect(
      () => deleted.apply(
        op(8, OperationKind.strokeCreate, {
          'value': {'color': 99},
        }, pageId: 'page', objectId: 'stroke'),
      ),
      throwsStateError,
    );
  });

  test('local pending survives stale higher-ranked remote response', () {
    final pending = PendingShareProjection(initial());
    final localMove = op(
      9,
      OperationKind.objectTransform,
      {
        'properties': {'dx': 27},
      },
      pageId: 'page',
      objectId: 'stroke',
      actor: 'local',
      clock: 6,
    );
    pending.enqueue(localMove);
    final remoteMove = op(
      10,
      OperationKind.objectTransform,
      {
        'properties': {'dx': 50},
      },
      pageId: 'page',
      objectId: 'stroke',
      actor: 'remote',
      clock: 8,
    );
    pending.accept(remoteMove);
    expect((stroke(pending.visible)['properties'] as Map)['dx'], 27);
    expect(pending.pending.keys, contains(id(9)));

    // The server's accepted precedence remains authoritative after ACK.
    pending.accept(localMove);
    expect((stroke(pending.visible)['properties'] as Map)['dx'], 50);
    expect(pending.pending, isEmpty);
  });

  test('remote deletion leaves unacknowledged local edit for recovery', () {
    final pending = PendingShareProjection(initial());
    pending.enqueue(
      op(11, OperationKind.objectSet, {
        'properties': {'color': 12},
      }, pageId: 'page', objectId: 'stroke'),
    );
    pending.accept(
      op(12, OperationKind.objectDelete, {},
          pageId: 'page', objectId: 'stroke'),
    );
    expect(pending.pending, hasLength(1));
    expect((strokeObjectCount(pending.visible)), 0);
  });

  test('remote edits preserve original untouched page map', () {
    final state = initial();
    final updated = state.apply(
      op(13, OperationKind.objectSet, {
        'properties': {'color': 3},
      }, pageId: 'page', objectId: 'stroke'),
    );
    expect((state.document!['pages'] as Map).length, 1);
    expect((stroke(state)['properties'] as Map)['color'], 1);
    expect((stroke(updated)['properties'] as Map)['color'], 3);
  });
}

int strokeObjectCount(ShareOperationProjection state) {
  final pages = state.document!['pages'] as Map;
  return ((pages['page'] as Map)['objects'] as Map).length;
}
