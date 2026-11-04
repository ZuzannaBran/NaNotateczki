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
    atoms = applyPlan(atoms, adapter.plan(atoms: atoms, newText: 'AC'));
    expect(OperationTextSequence.render(atoms), 'AC');
  });

  test('inserting over 256 characters preserves batch anchors', () {
    final adapter = ShareTextEditAdapter();
    final text = List.filled(257, 'x').join();
    final plan = adapter.plan(atoms: {}, newText: text);
    expect(plan, hasLength(2));
    expect(plan.every((item) => item.kind == OperationKind.textInsert), isTrue);
    final firstBatch = plan.first.payload['atoms'] as List;
    expect(plan.last.payload['afterAtomId'], (firstBatch.last as Map)['id']);
    expect(OperationTextSequence.render(applyPlan({}, plan)), text);
  });

  test('same text creates no duplicate operations', () {
    final adapter = ShareTextEditAdapter();
    final current = applyPlan(
      {},
      adapter.plan(atoms: {}, newText: 'unchanged'),
    );
    expect(adapter.plan(atoms: current, newText: 'unchanged'), isEmpty);
  });

  test('Quill deltas and legacy text chunks are handled safely', () {
    final adapter = ShareTextEditAdapter();
    final formatted = adapter.plan(
      atoms: {},
      newText: 'rich',
      changedDeltaJson: '[{"insert":"rich","attributes":{"bold":true}}]',
    );
    final formattedAtoms = applyPlan({}, formatted);
    expect(OperationTextSequence.renderDelta(formattedAtoms), [
      {
        'insert': 'rich',
        'attributes': {'bold': true},
      },
    ]);
    expect(
      () => adapter.plan(
        atoms: {},
        newText: 'a',
        changedDeltaJson: '[{"insert":{"image":"unverified"}}]',
      ),
      throwsFormatException,
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
    expect(() => adapter.plan(atoms: initial, newText: 'AX'), throwsStateError);
  });

  test('duplicate atom IDs are rejected before emitting an intent', () {
    const reusedId = '00000000-0000-4000-8000-000000000001';
    final adapter = ShareTextEditAdapter(createAtomId: () => reusedId);
    expect(() => adapter.plan(atoms: {}, newText: 'AB'), throwsStateError);
  });
  test('Unicode supplementary characters remain intact after replacement', () {
    final adapter = ShareTextEditAdapter();
    var state = applyPlan({}, adapter.plan(atoms: {}, newText: 'A😀B'));
    final changes = adapter.plan(atoms: state, newText: 'A🦊B');
    state = applyPlan(state, changes);
    expect(OperationTextSequence.render(state), 'A🦊B');
  });

  test('513 code points split into three insert and delete batches', () {
    final adapter = ShareTextEditAdapter();
    final initial = List.filled(513, 'x').join();
    final replacement = List.filled(513, 'y').join();
    var state = applyPlan({}, adapter.plan(atoms: {}, newText: initial));
    final changes = adapter.plan(atoms: state, newText: replacement);
    expect(
      changes.where((it) => it.kind == OperationKind.textDelete),
      hasLength(3),
    );
    expect(
      changes.where((it) => it.kind == OperationKind.textInsert),
      hasLength(3),
    );
    state = applyPlan(state, changes);
    expect(OperationTextSequence.render(state), replacement);
  });
  test('Quill images and PDFs emit atomic embedded assets', () {
    final adapter = ShareTextEditAdapter();
    const image = '[{"insert":"A"},'
        '{"insert":{"image":"asset:photo-1"}},'
        '{"insert":"B"}]';
    const pdf = '[{"insert":"A"},'
        '{"insert":{"pdf":"asset:document-1"}},'
        '{"insert":"B"}]';
    final created = adapter.plan(
      atoms: {},
      newText: 'A\uFFFCB',
      changedDeltaJson: image,
    );
    final initial = applyPlan({}, created);
    expect(OperationTextSequence.renderDelta(initial), [
      {'insert': 'A'},
      {
        'insert': {'image': 'asset:photo-1'},
      },
      {'insert': 'B'},
    ]);
    expect(
      adapter.plan(
        atoms: initial,
        newText: 'A\uFFFCB',
        changedDeltaJson: image,
      ),
      isEmpty,
    );
    final replaced = adapter.plan(
      atoms: initial,
      newText: 'A\uFFFCB',
      changedDeltaJson: pdf,
    );
    expect(replaced.map((item) => item.kind), [
      OperationKind.textDelete,
      OperationKind.textInsert,
    ]);
    final updated = applyPlan(initial, replaced);
    expect(OperationTextSequence.renderDelta(updated), [
      {'insert': 'A'},
      {
        'insert': {'pdf': 'asset:document-1'},
      },
      {'insert': 'B'},
    ]);
    expect(
      () => adapter.plan(
        atoms: initial,
        newText: 'A\uFFFCB',
        changedDeltaJson:
            '[{"insert":"A"},{"insert":{"image":"https://evil/x"}},'
            '{"insert":"B"}]',
      ),
      throwsFormatException,
    );
  });

  test('Quill format changes preserve atom IDs and can be undone', () {
    final adapter = ShareTextEditAdapter();
    final plain = applyPlan({}, adapter.plan(atoms: {}, newText: 'Hello'));
    final initialIds = OperationTextSequence.visibleIds(plain);
    final bold = adapter.plan(
      atoms: plain,
      newText: 'Hello',
      changedDeltaJson:
          '[{"insert":"He","attributes":{"bold":true}},'
          '{"insert":"llo"}]',
    );
    expect(bold.map((item) => item.kind).toSet(), {OperationKind.textFormat});
    final styled = applyPlan(plain, bold);
    expect(OperationTextSequence.visibleIds(styled), initialIds);
    expect(OperationTextSequence.renderDelta(styled), [
      {
        'insert': 'He',
        'attributes': {'bold': true},
      },
      {'insert': 'llo'},
    ]);
    final undo = adapter.plan(
      atoms: styled,
      newText: 'Hello',
      changedDeltaJson: '[{"insert":"Hello"}]',
    );
    expect(undo, isNotEmpty);
    expect(OperationTextSequence.renderDelta(applyPlan(styled, undo)), [
      {'insert': 'Hello'},
    ]);
  });

  test('Quill formatting preserves emoji and rejects mismatched text', () {
    final adapter = ShareTextEditAdapter();
    final plan = adapter.plan(
      atoms: {},
      newText: 'A😀',
      changedDeltaJson:
          '[{"insert":"A"},{"insert":"😀","attributes":{"italic":true}}]',
    );
    final state = applyPlan({}, plan);
    expect(OperationTextSequence.renderDelta(state), [
      {'insert': 'A'},
      {
        'insert': '😀',
        'attributes': {'italic': true},
      },
    ]);
    expect(
      () => adapter.plan(
        atoms: state,
        newText: 'A🦊',
        changedDeltaJson: '[{"insert":"A😀"}]',
      ),
      throwsFormatException,
    );
  });
}
