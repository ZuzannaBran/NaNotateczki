import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/library_state_merge.dart';

void main() {
  test('archived folders never resurrect without a recovered document', () {
    final current = <String, dynamic>{
      'folders': <String>[],
      'covers': <String, dynamic>{},
      'plannerTasks': <String, dynamic>{},
      'recentCoverColors': [1],
    };
    final archived = <String, dynamic>{
      'folders': ['Deleted'],
      'covers': {'Deleted': {'color': 7}},
      'plannerTasks': <String, dynamic>{},
      'recentCoverColors': [2],
    };
    final actual = mergeRecoveredLibraryMetadata(
      current: current,
      recovered: archived,
      recoveredUids: const {},
      restoredFolderPaths: const [],
    );
    expect(actual, current);
    expect(actual['folders'], isEmpty);
  });

  test('only recovered notebook restores its folder and ancestors', () {
    final current = <String, dynamic>{
      'folders': ['Current'],
      'covers': {'Current': {'color': 3}},
      'plannerTasks': {
        'new-planner': [
          {'id': 'account-task', 'title': 'Keep'},
        ],
      },
    };
    final archived = <String, dynamic>{
      'folders': ['Old', 'Class', 'Class/Math', 'Class/Math/Topic'],
      'covers': {
        'Old': {'color': 1},
        'Class': {'color': 2},
        'Class/Math': {'color': 4},
      },
      'plannerTasks': {
        'old-planner': [
          {'id': 'old-task', 'title': 'Do not replace'},
        ],
        'old-note': [
          {'id': 'new-task', 'title': 'Recover'},
        ],
      },
    };
    final merged = mergeRecoveredLibraryMetadata(
      current: current,
      recovered: archived,
      recoveredUids: const {
        'old-planner': 'new-planner',
        'old-note': 'new-note',
      },
      restoredFolderPaths: const ['Class/Math/Topic'],
    );
    expect(
      merged['folders'],
      ['Class', 'Class/Math', 'Class/Math/Topic', 'Current'],
    );
    expect((merged['covers'] as Map).containsKey('Old'), isFalse);
    expect((merged['covers'] as Map)['Current'], {'color': 3});
    expect((merged['covers'] as Map)['Class/Math'], {'color': 4});
    expect(
      (merged['plannerTasks'] as Map)['new-planner'],
      [
        {'id': 'account-task', 'title': 'Keep'},
      ],
    );
    expect(
      (merged['plannerTasks'] as Map)['new-note'],
      [
        {'id': 'new-task', 'title': 'Recover'},
      ],
    );
  });
}
