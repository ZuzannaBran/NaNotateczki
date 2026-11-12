import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/library_v2_operation_service.dart';
import 'package:program/data/sync/operation_protocol.dart';

OperationEnvelope operation(
  OperationKind kind,
  String id,
  int clock,
  Map<String, dynamic> payload, {
  String actor = 'device-a',
}) {
  final serial = clock.toString().padLeft(12, '0');
  final uuid = '11111111-2222-4333-8444-' +
      (actor == 'device-z' ? '999999999999' : serial);
  return OperationEnvelope(
    operationId: uuid,
    actorId: actor,
    actorSeq: clock,
    documentId: OperationEnvelope.libraryDocumentId,
    objectId: id,
    kind: kind,
    logicalClock: clock,
    payload: payload,
    dependencies: const [],
  );
}

void main() {
  const root = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const child = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const task = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

  test('folder subtree moves by stable ID and cannot form cycles', () {
    final created = [
      operation(OperationKind.folderCreate, root, 1, {
        'value': {'name': 'A', 'parentId': null},
      }),
      operation(OperationKind.folderCreate, child, 2, {
        'value': {'name': 'B', 'parentId': root},
      }),
    ];
    final moved = LibraryV2OperationReducer.replay([
      ...created,
      operation(OperationKind.folderSet, root, 3, {
        'properties': {'name': 'Renamed'},
      }),
    ]);
    expect(moved.folderIdsByPath['Renamed/B'], child);
    expect(() => LibraryV2OperationReducer.replay([
      ...created,
      operation(OperationKind.folderMove, root, 3, {
        'properties': {'parentId': child},
      }),
    ]), throwsStateError);
  });

  test('field ranks converge after concurrent edits and deletes never revive', () {
    final create = operation(OperationKind.folderCreate, root, 1, {
      'value': {'name': 'Original', 'parentId': null},
    });
    final older = operation(OperationKind.folderSet, root, 4, {
      'properties': {'name': 'Old'},
    }, actor: 'device-a');
    final newer = operation(OperationKind.folderSet, root, 4, {
      'properties': {'name': 'New'},
    }, actor: 'device-z');
    for (final changes in [[older, newer], [newer, older]]) {
      final state = LibraryV2OperationReducer.replay([create, ...changes]);
      expect(state.folderIdsByPath.keys, ['New']);
    }
    final deleted = operation(OperationKind.folderDelete, root, 5, {});
    final state = LibraryV2OperationReducer.replay([
      create, deleted, older,
    ]);
    expect(state.folderIdsByPath, isEmpty);
    expect(() => LibraryV2OperationReducer.replay([
      create, deleted, create,
    ]), throwsStateError);
  });

  test('simultaneous same-name folders retain both UIDs after replay', () {
    final first = operation(OperationKind.folderCreate, root, 1, {
      'value': {'name': 'School', 'parentId': null},
    });
    final second = operation(OperationKind.folderCreate, child, 2, {
      'value': {'name': 'School', 'parentId': null},
    });
    for (final order in [[first, second], [second, first]]) {
      final view = LibraryV2OperationReducer.replay(order);
      expect(view.folderIdsByPath['School'], root);
      expect(view.folderIdsByPath['School (bbbbbbbb)'], child);
      expect(view.folderIdsByPath.values.toSet(), {root, child});
    }
  });

  test('tasks survive separate field edits and retain planner identity', () {
    final created = operation(OperationKind.taskCreate, task, 1, {
      'value': {
        'id': task,
        'plannerUid': 'planner-1',
        'title': 'Read',
        'completed': false,
        'sortIndex': 2,
      },
    });
    final updated = operation(OperationKind.taskSet, task, 2, {
      'properties': {'completed': true},
    });
    final state = LibraryV2OperationReducer.replay([created, updated]);
    final entries = state.value['plannerTasks']['planner-1'] as List;
    expect(entries.single['title'], 'Read');
    expect(entries.single['completed'], true);
    final deleted = operation(OperationKind.taskDelete, task, 3, {});
    expect(
      (LibraryV2OperationReducer.replay(
        [created, updated, deleted, updated],
      ).value['plannerTasks'] as Map).isEmpty,
      true,
    );
  });
}
