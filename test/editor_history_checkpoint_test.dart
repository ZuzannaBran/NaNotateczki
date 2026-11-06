import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/editor_history_checkpoint.dart';

StoredEditorGesture gesture(String id, int before, int after) =>
    StoredEditorGesture(
      before: {'uid': 'doc', 'value': before},
      after: {'value': after, 'uid': 'doc'},
      operationId: id,
    );
EditorHistoryCheckpoint checkpoint({
  List<StoredEditorGesture>? undo,
  List<StoredEditorGesture> redo = const [],
}) => EditorHistoryCheckpoint(
  documentId: 'doc',
  ownerId: 'actor',
  headOperationId: 'head',
  undo: undo ?? [gesture('first', 0, 1), gesture('second', 1, 2)],
  redo: redo,
);

void main() {
  test('a checkpoint that fits keeps the same stacks and identity', () {
    final saved = checkpoint(redo: [gesture('redo', 2, 3)]);
    expect(identical(saved.fitToByteBudget(), saved), isTrue);
    expect(saved.fitToByteBudget().encode(), saved.encode());
  });

  test('byte fitting removes oldest Undo before any Redo without mutation', () {
    final old = StoredEditorGesture(
      before: {'uid': 'doc', 'text': '😀' * 2048},
      after: {'uid': 'doc', 'value': 1},
      operationId: 'old',
    );
    final recent = gesture('recent', 1, 2);
    final redo = gesture('redo', 2, 3);
    final saved = checkpoint(undo: [old, recent], redo: [redo]);
    final expected = checkpoint(undo: [recent], redo: [redo]);
    final limit = utf8.encode(expected.encode()).length;
    final fitted = saved.fitToByteBudget(byteLimit: limit);
    expect(fitted.encode(), expected.encode());
    expect(saved.undo.map((entry) => entry.operationId), ['old', 'recent']);
    expect(saved.redo.single.operationId, 'redo');
    expect(fitted.headOperationId, saved.headOperationId);
    expect(fitted.ownerId, saved.ownerId);
  });

  test('byte fitting drops the farthest Redo and retains its next step', () {
    final far = StoredEditorGesture(
      before: {'uid': 'doc', 'text': 'x' * 4096},
      after: {'uid': 'doc', 'value': 2},
      operationId: 'far',
    );
    final near = gesture('near', 1, 2);
    final saved = checkpoint(undo: [], redo: [far, near]);
    final expected = checkpoint(undo: [], redo: [near]);
    final limit = utf8.encode(expected.encode()).length;
    expect(saved.fitToByteBudget(byteLimit: limit).encode(), expected.encode());
    expect(saved.redo, hasLength(2));
  });

  test('an oversized single gesture becomes empty scoped metadata', () {
    final saved = checkpoint(
      undo: [
        StoredEditorGesture(
          before: {'uid': 'doc', 'text': 'x' * 4096},
          after: {'uid': 'doc', 'text': 'y' * 4096},
          operationId: 'huge',
        ),
      ],
    );
    final empty = checkpoint(undo: []);
    final limit = utf8.encode(empty.encode()).length;
    final fitted = saved.fitToByteBudget(byteLimit: limit);
    expect(fitted.encode(), empty.encode());
    expect(saved.undo, hasLength(1));
    expect(
      () => fitted.fitToByteBudget(byteLimit: limit - 1),
      throwsA(isA<EditorHistoryBudgetExceeded>()),
    );
    expect(() => fitted.fitToByteBudget(byteLimit: 0), throwsArgumentError);
  });

  test('only resource limits use the budget exception type', () {
    expect(
      () => checkpoint().encode(byteLimit: 1),
      throwsA(isA<EditorHistoryBudgetExceeded>()),
    );
    try {
      EditorHistoryCheckpoint.decode('{}');
      fail('Malformed history was accepted.');
    } on FormatException catch (error) {
      expect(error, isNot(isA<EditorHistoryBudgetExceeded>()));
    }
  });

  test('fitting retains the largest possible suffix of a full history', () {
    final entries = List.generate(
      50,
      (index) => StoredEditorGesture(
        before: {'uid': 'doc', 'value': index, 'text': 'x' * 1000},
        after: {'uid': 'doc', 'value': index + 1, 'text': 'x' * 1000},
        operationId: 'gesture-$index',
      ),
    );
    final expected = checkpoint(undo: entries.sublist(43));
    final limit = utf8.encode(expected.encode()).length;
    final fitted = checkpoint(undo: entries).fitToByteBudget(byteLimit: limit);
    expect(fitted.encode(), expected.encode());
    expect(
      () => checkpoint(undo: entries.sublist(42)).encode(byteLimit: limit),
      throwsA(isA<EditorHistoryBudgetExceeded>()),
    );
  });

  test(
    'checkpoint round trip preserves both stacks and deduplicates boundary states',
    () {
      final saved = checkpoint(
        undo: [gesture('first', 0, 1)],
        redo: [gesture('inverse', 1, 2)],
      );
      final json = saved.encode();
      expect((jsonDecode(json) as Map)['states'], hasLength(3));
      final restored = EditorHistoryCheckpoint.decode(json);
      expect(restored.undo.single.operationId, 'first');
      expect(restored.redo.single.operationId, 'inverse');
      expect(restored.undo.single.after, {'uid': 'doc', 'value': 1});
      expect(restored.encode(), json);
    },
  );

  test('input maps and returned states cannot mutate a checkpoint', () {
    final before = <String, dynamic>{
      'uid': 'doc',
      'nested': <String, dynamic>{'value': 1},
    };
    final entry = StoredEditorGesture(
      before: before,
      after: {'uid': 'doc'},
      operationId: 'first',
    );
    final entries = [entry];
    final saved = checkpoint(undo: entries);
    (before['nested'] as Map)['value'] = 9;
    entries.clear();
    (entry.before['nested'] as Map)['value'] = 10;
    expect(saved.undo, hasLength(1));
    expect(saved.undo.single.before['nested'], {'value': 1});
    expect(() => saved.undo.clear(), throwsUnsupportedError);
  });

  test('scope, duplicate gestures and gesture budget are strict', () {
    expect(
      () => checkpoint(
        undo: [
          StoredEditorGesture(
            before: {'uid': 'foreign'},
            after: {'uid': 'doc'},
            operationId: 'first',
          ),
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => checkpoint(
        undo: [gesture('same', 0, 1)],
        redo: [gesture('same', 1, 2)],
      ),
      throwsFormatException,
    );
    expect(
      () => checkpoint(undo: List.generate(51, (i) => gesture('$i', i, i + 1))),
      throwsFormatException,
    );
    expect(
      () => StoredEditorGesture(
        before: {'uid': 'doc'},
        after: {'uid': 'doc'},
        operationId: '',
      ),
      throwsFormatException,
    );
  });

  test('non-JSON values, nonfinite numbers and deep nesting are refused', () {
    for (final value in [
      double.nan,
      double.infinity,
      Object(),
      {1: 'value'},
    ]) {
      expect(
        () => StoredEditorGesture(
          before: {'uid': 'doc', 'value': value},
          after: {'uid': 'doc'},
          operationId: 'first',
        ),
        throwsFormatException,
      );
    }
    Object value = 'leaf';
    for (var i = 0; i < 70; i++) {
      value = [value];
    }
    expect(
      () => StoredEditorGesture(
        before: {'uid': 'doc', 'value': value},
        after: {'uid': 'doc'},
        operationId: 'first',
      ),
      throwsFormatException,
    );
  });

  test('byte budget measures UTF-8 and is validated', () {
    final saved = checkpoint(
      undo: [
        StoredEditorGesture(
          before: {'uid': 'doc'},
          after: {'uid': 'doc', 'value': '😀' * 20},
          operationId: 'first',
        ),
      ],
    );
    final bytes = utf8.encode(saved.encode()).length;
    expect(() => saved.encode(byteLimit: bytes - 1), throwsFormatException);
    expect(saved.encode(byteLimit: bytes), isNotEmpty);
    expect(() => saved.encode(byteLimit: 0), throwsArgumentError);
  });

  test(
    'tampered state, missing state, unknown version and unused state fail closed',
    () {
      for (final mutate in <void Function(Map)>[
        (root) => root['version'] = 2,
        (root) => root['version'] = 1.0,
        (root) => root['extra'] = true,
        (root) => ((root['states'] as Map).values.first as Map)['value'] = 99,
        (root) => (root['states'] as Map).clear(),
        (root) => (root['states'] as Map)['extra'] = {'uid': 'doc'},
        (root) => (root['undo'] as List).first['operationId'] = null,
        (root) => root['undo'] = List.filled(51, (root['undo'] as List).first),
      ]) {
        final root = jsonDecode(checkpoint().encode()) as Map;
        mutate(root);
        expect(
          () => EditorHistoryCheckpoint.decode(jsonEncode(root)),
          throwsFormatException,
        );
      }
    },
  );
}
