import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/notebook_merge.dart';

void main() {
  Map<String, dynamic> note() => {
    'uid': 'same',
    'title': 'Notes',
    'updatedAt': '2026-11-01T10:00:00.000Z',
    'pages': [
      {
        'id': 'page',
        'title': 'Page',
        'isBookmarked': false,
        'inkStrokes': [
          {
            'id': 'old',
            'points': [1],
          },
        ],
        'textBlocks': <dynamic>[],
        'imageBlocks': <dynamic>[],
      },
    ],
  };

  test('independent text addition and ink deletion stay in one file', () {
    final base = note();
    final local = note();
    final remote = note();
    (local['pages'] as List).first['textBlocks'] = [
      {'id': 'text', 'text': 'Added'},
    ];
    (remote['pages'] as List).first['inkStrokes'] = <dynamic>[];
    final merged = mergeNotebookChanges(base, local, remote)!;
    expect(merged['uid'], 'same');
    final page = (merged['pages'] as List).single;
    expect(page['textBlocks'], hasLength(1));
    expect(page['inkStrokes'], isEmpty);
  });

  test('changes to different fields merge', () {
    final base = note();
    final local = note();
    final remote = note();
    (local['pages'] as List).first['title'] = 'Edited';
    (remote['pages'] as List).first['isBookmarked'] = true;
    final page =
        (mergeNotebookChanges(base, local, remote)!['pages'] as List).single;
    expect(page['title'], 'Edited');
    expect(page['isBookmarked'], isTrue);
  });

  test('editing an object deleted elsewhere is a conflict', () {
    final base = note();
    final local = note();
    final remote = note();
    (local['pages'] as List).first['inkStrokes'] = [
      {
        'id': 'old',
        'points': [1, 2],
      },
    ];
    (remote['pages'] as List).first['inkStrokes'] = <dynamic>[];
    expect(mergeNotebookChanges(base, local, remote), isNull);
  });

  test('two different title edits conflict', () {
    final base = note();
    final local = note()..['title'] = 'Local title';
    final remote = note()..['title'] = 'Remote title';
    expect(mergeNotebookChanges(base, local, remote), isNull);
  });

  test('independent new elements on two devices are preserved', () {
    final base = note();
    final local = note();
    final remote = note();
    (local['pages'] as List).first['textBlocks'] = [
      {'id': 'a', 'text': 'A'},
    ];
    (remote['pages'] as List).first['textBlocks'] = [
      {'id': 'b', 'text': 'B'},
    ];
    final page =
        (mergeNotebookChanges(base, local, remote)!['pages'] as List).single;
    expect(
      (page['textBlocks'] as List).map((e) => e['id']),
      containsAll(['a', 'b']),
    );
  });
  test('in-flight guest edits do not delete unseen host ink', () {
    final submitted = note();
    final visibleAfterSend = note();
    final accepted = note();
    final submittedStrokes =
        (submitted['pages'] as List).first['inkStrokes'] as List;
    submittedStrokes.add({'id': 'guest-a', 'points': [2]});
    final localStrokes =
        (visibleAfterSend['pages'] as List).first['inkStrokes'] as List;
    localStrokes.add({'id': 'guest-a', 'points': [2]});
    localStrokes.add({'id': 'guest-c', 'points': [4]});
    final acceptedStrokes =
        (accepted['pages'] as List).first['inkStrokes'] as List;
    acceptedStrokes.add({'id': 'guest-a', 'points': [2]});
    acceptedStrokes.add({'id': 'host-b', 'points': [3]});

    final rebased = mergeNotebookChanges(
      submitted,
      visibleAfterSend,
      accepted,
    )!;
    final ids = ((rebased['pages'] as List).single['inkStrokes'] as List)
        .map((stroke) => stroke['id']);
    expect(ids, containsAll(['old', 'guest-a', 'guest-c', 'host-b']));
    expect(ids, hasLength(4));
  });

  test('rebase preserves a deliberate deletion after an acknowledged send', () {
    final sent = note();
    final current = note();
    final accepted = note();
    (sent['pages'] as List).first['inkStrokes'].add({
      'id': 'guest-a',
      'points': [2],
    });
    (current['pages'] as List).first['inkStrokes'].add({
      'id': 'guest-c',
      'points': [4],
    });
    (accepted['pages'] as List).first['inkStrokes'].addAll([
      {'id': 'guest-a', 'points': [2]},
      {'id': 'host-b', 'points': [3]},
    ]);

    final rebased = mergeNotebookChanges(sent, current, accepted)!;
    final ids = ((rebased['pages'] as List).single['inkStrokes'] as List)
        .map((stroke) => stroke['id']);
    expect(ids, containsAll(['old', 'guest-c', 'host-b']));
    expect(ids, isNot(contains('guest-a')));
  });

}
