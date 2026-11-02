import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/library_state_merge.dart';

void main() {
  test('independent folder additions merge while known deletion persists', () {
    final base = {
      'folders': ['Notes', 'Deleted'],
      'covers': <String, dynamic>{},
      'plannerTasks': <String, dynamic>{},
      'recentCoverColors': <int>[],
    };
    final local = {
      ...base,
      'folders': ['Notes', 'Device B'],
    };
    final remote = {
      ...base,
      'folders': ['Notes', 'Deleted', 'Device A'],
    };
    final merged = mergeAccountLibraryState(
      base: base,
      local: local,
      remote: remote,
    );
    expect(merged['folders'], ['Device A', 'Device B', 'Notes']);
  });

  test('remote folder deletion does not reappear from unchanged device', () {
    final base = {
      'folders': ['Notes', 'Archive'],
    };
    final merged = mergeAccountLibraryState(
      base: base,
      local: base,
      remote: {
        'folders': ['Notes'],
      },
    );
    expect(merged['folders'], ['Notes']);
  });

  test('task edits survive independent remote additions', () {
    final task = {
      'id': 'task-1',
      'title': 'Read',
      'completed': false,
      'deadline': null,
      'deadlineHasTime': false,
    };
    final base = {
      'plannerTasks': {
        'notebook-1': [task],
      },
    };
    final local = {
      'plannerTasks': {
        'notebook-1': [
          {...task, 'completed': true},
        ],
      },
    };
    final remote = {
      'plannerTasks': {
        'notebook-1': [
          task,
          {...task, 'id': 'task-2', 'title': 'Write'},
        ],
      },
    };
    final merged = mergeAccountLibraryState(
      base: base,
      local: local,
      remote: remote,
    );
    final tasks = merged['plannerTasks']['notebook-1'] as List;
    expect(tasks, hasLength(2));
    expect(tasks.firstWhere((t) => t['id'] == 'task-1')['completed'], true);
    expect(tasks.firstWhere((t) => t['id'] == 'task-2')['title'], 'Write');
  });

  test('remote task deletion preserves only an edited numbered draft', () {
    final task = {'id': 'task-1', 'title': 'Read', 'completed': false};
    final base = {
      'plannerTasks': {
        'notebook-1': [task],
      },
    };
    final local = {
      'plannerTasks': {
        'notebook-1': [
          {...task, 'title': 'Read chapter 1'},
        ],
      },
    };
    final remote = {
      'plannerTasks': {'notebook-1': <dynamic>[]},
    };

    final merged = mergeAccountLibraryState(
      base: base,
      local: local,
      remote: remote,
    );
    final tasks = merged['plannerTasks']['notebook-1'] as List;
    expect(tasks, hasLength(1));
    expect(tasks.single['id'], isNot('task-1'));
    expect(tasks.single['title'], 'Read chapter 1 (1)');
    expect(
      mergeAccountLibraryState(
        base: base,
        local: local,
        remote: remote,
      )['plannerTasks']['notebook-1'],
      tasks,
    );
  });

  test('simultaneous edits of the same task retain both versions', () {
    final task = {'id': 'task-1', 'title': 'Read', 'completed': false};
    final merged = mergeAccountLibraryState(
      base: {
        'plannerTasks': {
          'planner-1': [task],
        },
      },
      local: {
        'plannerTasks': {
          'planner-1': [
            {...task, 'title': 'Read chapter 3'},
          ],
        },
      },
      remote: {
        'plannerTasks': {
          'planner-1': [
            {...task, 'title': 'Read chapter 5'},
          ],
        },
      },
    );
    final tasks = merged['plannerTasks']['planner-1'] as List;
    expect(tasks, hasLength(2));
    expect(tasks.any((task) => task['title'] == 'Read chapter 5'), isTrue);
    expect(tasks.any((task) => task['title'] == 'Read chapter 3 (1)'), isTrue);
    expect(tasks.map((task) => task['id']).toSet(), hasLength(2));
  });

  test('first device sync does not erase a different local folder', () {
    final merged = mergeAccountLibraryState(
      base: null,
      local: {
        'folders': ['Local'],
      },
      remote: {
        'folders': ['Remote'],
      },
    );
    expect(merged['folders'], ['Local', 'Remote']);
  });
}
