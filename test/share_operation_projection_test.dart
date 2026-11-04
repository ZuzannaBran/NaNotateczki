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
    op(
      3,
      OperationKind.strokeCreate,
      {
        'value': {'color': 1, 'dx': 0},
      },
      pageId: 'page',
      objectId: 'stroke',
    ),
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
      6,
      OperationKind.objectDelete,
      {},
      pageId: 'page',
      objectId: 'stroke',
    );
    final edit = op(
      7,
      OperationKind.objectSet,
      {
        'properties': {'color': 99},
      },
      pageId: 'page',
      objectId: 'stroke',
    );
    final deleted = initial().apply(delete).apply(edit);
    final objects =
        ((deleted.document!['pages'] as Map)['page'] as Map)['objects'] as Map;
    expect(objects, isEmpty);
    expect(
      () => deleted.apply(
        op(
          8,
          OperationKind.strokeCreate,
          {
            'value': {'color': 99},
          },
          pageId: 'page',
          objectId: 'stroke',
        ),
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
      op(
        11,
        OperationKind.objectSet,
        {
          'properties': {'color': 12},
        },
        pageId: 'page',
        objectId: 'stroke',
      ),
    );
    pending.accept(
      op(
        12,
        OperationKind.objectDelete,
        {},
        pageId: 'page',
        objectId: 'stroke',
      ),
    );
    expect(pending.pending, hasLength(1));
    expect(strokeObjectCount(pending.visible), 0);
    expect(pending.unresolved, contains(id(11)));
  });

  test('remote edits copy only the touched page and object', () {
    var state = initial();
    state = state.apply(
      op(14, OperationKind.pageCreate, {
        'value': {'title': 'Unrelated page'},
      }, objectId: 'other-page'),
    );
    state = state.apply(
      op(
        15,
        OperationKind.strokeCreate,
        {
          'value': {'color': 7},
        },
        pageId: 'page',
        objectId: 'untouched-stroke',
      ),
    );
    final beforePages = state.document!['pages'] as Map;
    final beforeObjects = (beforePages['page'] as Map)['objects'] as Map;
    final updated = state.apply(
      op(
        13,
        OperationKind.objectSet,
        {
          'properties': {'color': 3},
        },
        pageId: 'page',
        objectId: 'stroke',
      ),
    );
    final afterPages = updated.document!['pages'] as Map;
    final afterObjects = (afterPages['page'] as Map)['objects'] as Map;
    expect(identical(state.document, updated.document), isFalse);
    expect(
      identical(beforePages['other-page'], afterPages['other-page']),
      isTrue,
    );
    expect(identical(beforePages['page'], afterPages['page']), isFalse);
    expect(
      identical(
        beforeObjects['untouched-stroke'],
        afterObjects['untouched-stroke'],
      ),
      isTrue,
    );
    expect(identical(beforeObjects['stroke'], afterObjects['stroke']), isFalse);
    expect((stroke(state)['properties'] as Map)['color'], 1);
    expect((stroke(updated)['properties'] as Map)['color'], 3);
  });
  test('v2 moves an image between pages without copying other objects', () {
    var state = initial();
    state = state.apply(op(
      40,
      OperationKind.pageCreate,
      {'value': {'title': 'Destination'}},
      objectId: 'target',
    ));
    final untouched = (state.document!['pages'] as Map)['target'];
    final moved = state.apply(op(
      41,
      OperationKind.objectMove,
      {'toPageId': 'target', 'sortIndex': 2},
      pageId: 'page',
      objectId: 'stroke',
    ));
    expect(strokeObjectCount(moved), 0);
    final movedNode = ((moved.document!['pages'] as Map)['target'] as Map)[
        'objects'] as Map;
    expect((movedNode['stroke'] as Map)['properties'], {
      'color': 1,
      'dx': 0,
      'sortIndex': 2,
    });
    expect(identical(untouched, (moved.document!['pages'] as Map)['target']),
        isFalse);
    expect(strokeObjectCount(state), 1);
    expect(
      () => moved.apply(op(
        42,
        OperationKind.objectMove,
        {'toPageId': 'missing', 'sortIndex': 0},
        pageId: 'target',
        objectId: 'stroke',
      )),
      throwsStateError,
    );
  });

  test('v2 applies Quill attributes without replacing existing text IDs', () {
    var state = initial().apply(op(
      50,
      OperationKind.objectCreate,
      {'value': {'objectType': 'text', 'text': ''}},
      pageId: 'page',
      objectId: 'text',
    ));
    state = state.apply(op(
      51,
      OperationKind.textInsert,
      {
        'afterAtomId': null,
        'atoms': [
          {'id': id(71), 'text': 'X', 'attributes': {'bold': true}},
        ],
      },
      pageId: 'page',
      objectId: 'text',
    ));
    state = state.apply(op(
      52,
      OperationKind.textFormat,
      {
        'atomIds': [id(71)],
        'attributes': {'bold': null, 'color': 'red'},
      },
      pageId: 'page',
      objectId: 'text',
      clock: 4,
    ));
    final node = (((state.document!['pages'] as Map)['page'] as Map)[
        'objects'] as Map)['text'] as Map;
    expect((node['properties'] as Map)['text'], 'X');
    expect((node['properties'] as Map)['delta'], [
      {'insert': 'X', 'attributes': {'color': 'red'}},
    ]);
    expect((node['textAtoms'] as Map).keys, contains(id(71)));
    expect(
      () => state.apply(op(
        53,
        OperationKind.objectSet,
        {'properties': {'delta': []}},
        pageId: 'page',
        objectId: 'text',
      )),
      throwsStateError,
    );
  });

  test('optimistic asset attach requires a verified upload receipt', () {
    const digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    var state = initial().apply(op(
      60,
      OperationKind.objectCreate,
      {'value': {'objectType': 'image'}},
      pageId: 'page',
      objectId: 'photo',
    ));
    final attach = op(
      61,
      OperationKind.assetAttach,
      {
        'assetId': 'photo-asset',
        'sha256': digest,
        'sizeBytes': 15,
        'mediaType': 'image/png',
      },
      pageId: 'page',
      objectId: 'photo',
      clock: 5,
    );
    final pending = PendingShareProjection(state);
    expect(() => pending.enqueue(attach), throwsStateError);
    pending.markAssetVerified(digest);
    pending.enqueue(attach);
    final projected = pending.visible;
    final node = ((((projected.document!['pages'] as Map)['page'] as Map)[
        'objects'] as Map)['photo']) as Map;
    expect((node['assets'] as Map)['photo-asset'], {
      'sha256': digest,
      'sizeBytes': 15,
      'mediaType': 'image/png',
    });
    pending.accept(attach);
    expect(pending.pending, isEmpty);
    final detached = pending.confirmed.apply(op(
      62,
      OperationKind.assetDetach,
      {'assetId': 'photo-asset'},
      pageId: 'page',
      objectId: 'photo',
      clock: 6,
    ));
    final detachedNode = ((((detached.document!['pages'] as Map)['page'] as Map)[
        'objects'] as Map)['photo']) as Map;
    expect(detachedNode['assets'], isEmpty);
    expect((node['assets'] as Map).length, 1);
  });

  test('canvas ordering is stable across different insertion histories', () {
    final base = initial().apply(op(
      80,
      OperationKind.objectCreate,
      {
        'value': {'objectType': 'image', 'sortIndex': 1},
      },
      pageId: 'page',
      objectId: 'image-z',
    ));
    final next = base.apply(op(
      81,
      OperationKind.objectCreate,
      {
        'value': {'objectType': 'image', 'sortIndex': 0},
      },
      pageId: 'page',
      objectId: 'image-a',
    ));
    expect(next.orderedObjectIds('page'), [
      'image-a',
      'stroke',
      'image-z',
    ]);
    expect(next.orderedObjectIds('nonexistent-page'), isEmpty);
    final updated = next.apply(op(
      82,
      OperationKind.objectReorder,
      {
        'properties': {'sortIndex': 3},
      },
      pageId: 'page',
      objectId: 'image-a',
      clock: 9,
    ));
    expect(updated.orderedObjectIds('page'), [
      'stroke',
      'image-z',
      'image-a',
    ]);
    expect(next.orderedObjectIds('page'), [
      'image-a',
      'stroke',
      'image-z',
    ]);
  });

}

int strokeObjectCount(ShareOperationProjection state) {
  final pages = state.document!['pages'] as Map;
  return ((pages['page'] as Map)['objects'] as Map).length;
}
