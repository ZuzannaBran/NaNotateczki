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
}
