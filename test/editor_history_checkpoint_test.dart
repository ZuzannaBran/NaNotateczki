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
