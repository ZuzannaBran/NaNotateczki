import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/share_operation_projection.dart';
import 'package:program/data/sync/share_ink_edit_adapter.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';

NotePage page(List<InkStroke> strokes) => NotePage(
  id: 'page-1',
  title: 'Page',
  textBlocks: [],
  imageBlocks: [],
  inkStrokes: strokes,
  isBookmarked: false,
);

InkStroke ink(
  String id, {
  int color = 0xFF112233,
  double dx = 4,
  double width = 2,
}) => InkStroke(
  id: id,
  points: [InkPoint(dx: dx, dy: 8, pressure: 0.7)],
  color: Color(color),
  width: width,
  tool: DrawingTool.pen,
);

void main() {
  final adapter = ShareInkEditAdapter();

  test('completed stroke is one operation with exact point data', () {
    final changes = adapter.plan(
      before: page([]),
      after: page([ink('stroke')]),
    );
    expect(changes, hasLength(1));
    expect(changes.single.kind, OperationKind.strokeCreate);
    expect(changes.single.pageId, 'page-1');
    expect(changes.single.objectId, 'stroke');
    final fields = changes.single.payload['value'] as Map<String, dynamic>;
    expect(fields['points'], [[4.0, 8.0, 0.7]]);
    final decoded = adapter.decode('stroke', {
      'type': 'stroke.create',
      'properties': fields,
    });
    expect(decoded.id, 'stroke');
    expect(decoded.points.single.dx, 4);
    expect(decoded.color.toARGB32(), 0xFF112233);
    expect(decoded.tool, DrawingTool.pen);
  });

  test('moving and recoloring produce separate object changes', () {
    final old = ink('stroke');
    final changes = adapter.plan(
      before: page([old]),
      after: page([ink('stroke', dx: 12, color: 0xFFBB1122)]),
    );
    expect(changes.map((item) => item.kind), [
      OperationKind.objectTransform,
      OperationKind.objectSet,
    ]);
    expect((changes.first.payload['properties'] as Map).keys, ['points']);
    expect(
      (changes.last.payload['properties'] as Map).keys,
      ['colorValue'],
    );
    expect(adapter.plan(
      before: page([old]),
      after: page([ink('stroke')]),
    ), isEmpty);
  });

  test('eraser records tombstone and updates remaining z-order', () {
    final changes = adapter.plan(
      before: page([ink('deleted'), ink('kept')]),
      after: page([ink('kept')]),
    );
    expect(changes.first.kind, OperationKind.objectDelete);
    expect(changes.first.objectId, 'deleted');
    expect(changes.first.payload, isEmpty);
    expect(changes.last.kind, OperationKind.objectReorder);
    expect(changes.last.objectId, 'kept');
  });

  test('independent addition does not send unchanged ink', () {
    final changes = adapter.plan(
      before: page([ink('existing')]),
      after: page([ink('existing'), ink('new')]),
    );
    expect(changes, hasLength(1));
    expect(changes.single.objectId, 'new');
    expect(changes.single.kind, OperationKind.strokeCreate);
  });

  test('duplicates, malformed strokes and other pages fail closed', () {
    expect(
      () => adapter.plan(
        before: page([]),
        after: page([ink('dup'), ink('dup')]),
      ),
      throwsStateError,
    );
    expect(
      () => adapter.plan(
        before: page([]),
        after: page([InkStroke(
          id: 'bad',
          points: [],
          color: const Color(0xFF000000),
          width: 2,
          tool: DrawingTool.pen,
        )]),
      ),
      throwsStateError,
    );
    expect(
      () => adapter.plan(
        before: page([]),
        after: page([]).copyWith(id: 'another-page'),
      ),
      throwsArgumentError,
    );
    expect(
      () => adapter.decode('stroke', {
        'type': 'stroke.create',
        'properties': {
          'colorValue': 0xFF000000,
          'width': 1,
          'toolIndex': DrawingTool.pen.index,
          'points': [[double.nan, 4, 1]],
        },
      }),
      throwsFormatException,
    );
  });

  test('concurrent color and movement converge through the v2 reducer', () {
    String uuid(int number) => '00000000-0000-4000-8000-' +
        number.toString().padLeft(12, '0');
    OperationEnvelope op(
      int number,
      OperationKind kind,
      Map<String, dynamic> payload, {
      String? pageId,
      String? objectId,
      String actor = 'actor',
    }) => OperationEnvelope(
      operationId: uuid(number),
      actorId: actor,
      actorSeq: number,
      documentId: 'notebook',
      pageId: pageId,
      objectId: objectId,
      kind: kind,
      payload: payload,
      dependencies: const [],
      logicalClock: number,
    );

    var initial = ShareOperationProjection.empty();
    initial = initial.apply(
      op(1, OperationKind.documentCreate, {'value': {}}),
    );
    initial = initial.apply(
      op(2, OperationKind.pageCreate, {'value': {}},
          objectId: 'page-1'),
    );
    final create = adapter.plan(
      before: page([]),
      after: page([ink('stroke')]),
    ).single;
    initial = initial.apply(
      op(3, create.kind, create.payload,
          pageId: create.pageId, objectId: create.objectId),
    );
    final style = adapter.plan(
      before: page([ink('stroke')]),
      after: page([ink('stroke', color: 0xFFAA7788)]),
    ).single;
    final movement = adapter.plan(
      before: page([ink('stroke')]),
      after: page([ink('stroke', dx: 25)]),
    ).single;
    final styleOp = op(4, style.kind, style.payload,
        pageId: style.pageId, objectId: style.objectId, actor: 'alice');
    final movementOp = op(5, movement.kind, movement.payload,
        pageId: movement.pageId, objectId: movement.objectId, actor: 'bob');
    final left = initial.apply(styleOp).apply(movementOp);
    final right = initial.apply(movementOp).apply(styleOp);
    expect(left.document, right.document);

    final objects = ((left.document!['pages'] as Map)['page-1']
        as Map)['objects'] as Map;
    final merged = adapter.decode(
      'stroke', objects['stroke'] as Map<String, dynamic>,
    );
    expect(merged.points.single.dx, 25);
    expect(merged.color.toARGB32(), 0xFFAA7788);

    final deleted = left.apply(
      op(6, OperationKind.objectDelete, {},
          pageId: 'page-1', objectId: 'stroke'),
    );
    expect(
      () => deleted.apply(
        op(7, create.kind, create.payload,
            pageId: create.pageId, objectId: create.objectId),
      ),
      throwsStateError,
    );
  });
}
