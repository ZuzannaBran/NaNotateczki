import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_text_sequence.dart';
import 'package:program/data/sync/share_text_edit_adapter.dart';
import 'package:uuid/uuid.dart';

Map<String, dynamic> applyPlan(
  Map<String, dynamic> initial,
  List<ShareTextIntent> plan,
) {
  var state = initial;
  for (var index = 0; index < plan.length; index++) {
    final intent = plan[index];
    final op = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'local-guest',
      actorSeq: index + 1,
      documentId: 'doc',
      pageId: 'page',
      objectId: 'text',
      kind: intent.kind,
      payload: intent.payload,
      dependencies: const [],
      logicalClock: index + 100,
    );
    op.validateForV2Projection();
    state = OperationTextSequence.apply(state, op);
  }
  return state;
}

void main() {
  test('typing, replacing and deleting a middle character', () {
    final adapter = ShareTextEditAdapter();
    var atoms = applyPlan({}, adapter.plan(atoms: {}, newText: 'ABC'));
    expect(OperationTextSequence.render(atoms), 'ABC');
    final replacement = adapter.plan(atoms: atoms, newText: 'AXC');
    expect(replacement.map((item) => item.kind), [
      OperationKind.textDelete,
      OperationKind.textInsert,
    ]);
    atoms = applyPlan(atoms, replacement);
    expect(OperationTextSequence.render(atoms), 'AXC');
    atoms = applyPlan(
      atoms, adapter.plan(atoms: atoms, newText: 'AC'),
    );
    expect(OperationTextSequence.render(atoms), 'AC');
  });

  test('inserting over 256 characters preserves batch anchors', () {
    final adapter = ShareTextEditAdapter();
    final text = List.filled(257, 'x').join();
    final plan = adapter.plan(atoms: {}, newText: text);
    expect(plan, hasLength(2));
    expect(plan.every((item) => item.kind == OperationKind.textInsert), isTrue);
    final firstBatch = plan.first.payload['atoms'] as List;
    expect(plan.last.payload['afterAtomId'],
        (firstBatch.last as Map)['id']);
    expect(OperationTextSequence.render(applyPlan({}, plan)), text);
  });

  test('same text creates no duplicate operations', () {
    final adapter = ShareTextEditAdapter();
    final current = applyPlan(
      {}, adapter.plan(atoms: {}, newText: 'unchanged'),
    );
    expect(adapter.plan(atoms: current, newText: 'unchanged'), isEmpty);
  });

  test('rich formatting and legacy text chunks fail closed', () {
    final adapter = ShareTextEditAdapter();
    expect(
      () => adapter.plan(
        atoms: {},
        newText: 'rich',
        changedDeltaJson: '[{"insert":"rich"}]',
      ),
      throwsUnsupportedError,
    );
    final initial = OperationTextSequence.apply(
      {},
      OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'actor',
        actorSeq: 1,
        documentId: 'doc',
        pageId: 'page',
        objectId: 'text',
        kind: OperationKind.textInsert,
        payload: {
          'afterAtomId': null,
          'atoms': [
            {'id': const Uuid().v4(), 'text': 'AB'},
          ],
        },
        dependencies: const [],
        logicalClock: 1,
      ),
    );
    expect(
      () => adapter.plan(atoms: initial, newText: 'AX'),
      throwsStateError,
    );
  });

  test('duplicate atom IDs are rejected before emitting an intent', () {
    const reusedId = '00000000-0000-4000-8000-000000000001';
    final adapter = ShareTextEditAdapter(createAtomId: () => reusedId);
    expect(
      () => adapter.plan(atoms: {}, newText: 'AB'),
      throwsStateError,
    );
  });
}
