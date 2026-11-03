import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/shared_edit_conflicts.dart';

Map<String, dynamic> _doc({
  required String text,
  required List<Map<String, dynamic>> strokes,
}) => {
  'uid': 'original',
  'pages': [
    {
      'id': 'page-1',
      'title': 'Page',
      'textBlocks': [
        {'id': 'text-1', 'text': text},
      ],
      'imageBlocks': <Map<String, dynamic>>[],
      'inkStrokes': strokes,
    },
  ],
};

void main() {
  test('remote ink can merge with an independent accepted text edit', () {
    final base = _doc(text: 'old', strokes: []);
    final submitted = _doc(text: 'new', strokes: []);
    final accepted = _doc(
      text: 'new',
      strokes: [
        {
          'id': 'ink-1',
          'points': [1],
        },
      ],
    );
    expect(hasRejectedSharedEdits(base, submitted, accepted), isFalse);
  });

  test('first accepted text edit cannot silently erase losing edit', () {
    final base = _doc(text: 'old', strokes: []);
    final submitted = _doc(text: 'second', strokes: []);
    final accepted = _doc(text: 'first', strokes: []);
    expect(hasRejectedSharedEdits(base, submitted, accepted), isTrue);
  });

  test('lost deletion and lost new ink both count as rejected changes', () {
    final base = _doc(
      text: 'old',
      strokes: [
        {
          'id': 'ink-old',
          'points': [1],
        },
      ],
    );
    final deleteStroke = _doc(text: 'old', strokes: []);
    final addStroke = _doc(
      text: 'old',
      strokes: [
        {
          'id': 'ink-old',
          'points': [1],
        },
        {
          'id': 'ink-new',
          'points': [2],
        },
      ],
    );
    expect(hasRejectedSharedEdits(base, deleteStroke, base), isTrue);
    expect(hasRejectedSharedEdits(base, addStroke, base), isTrue);
  });

  test('reordered JSON object keys do not cause false conflicts', () {
    final base = _doc(text: 'old', strokes: []);
    final submitted = _doc(text: 'new', strokes: []);
    final accepted = {
      'pages': [
        {
          'textBlocks': [
            {'text': 'new', 'id': 'text-1'},
          ],
          'inkStrokes': [],
          'imageBlocks': [],
          'title': 'Page',
          'id': 'page-1',
        },
      ],
      'uid': 'original',
    };
    expect(hasRejectedSharedEdits(base, submitted, accepted), isFalse);
  });
  test(
    'subsequent remote revision uses the visible pre-acknowledgment base',
    () {
      final displayed = _doc(text: 'mine', strokes: []);
      final acknowledged = _doc(
        text: 'mine',
        strokes: [
          {'id': 'remote-ink', 'points': [1, 2]},
        ],
      );
      final expected = sharedGuestVisibleBaseline(
        acknowledged: acknowledged,
        notYetInstalled: displayed,
      );
      expect(
        canInstallSharedGuestRevision(
          incomingRevision: 12,
          confirmedRevision: 11,
          expectedLocal: expected,
          visibleLocal: displayed,
        ),
        isTrue,
      );
      expect(
        canInstallSharedGuestRevision(
          incomingRevision: 12,
          confirmedRevision: 11,
          expectedLocal: acknowledged,
          visibleLocal: displayed,
        ),
        isFalse,
      );
    },
  );

  test('a delayed revision never replaces a newer guest acknowledgement', () {
    final base = _doc(text: 'saved', strokes: []);
    expect(
      canInstallSharedGuestRevision(
        incomingRevision: 7,
        confirmedRevision: 8,
        expectedLocal: base,
        visibleLocal: base,
      ),
      isFalse,
    );
  });

  test('a stroke still in memory blocks remote replacement', () {
    final saved = _doc(text: 'saved', strokes: []);
    final visible = _doc(
      text: 'saved',
      strokes: [
        {'id': 'new-ink', 'points': [1, 2]},
      ],
    );
    expect(
      canInstallSharedGuestRevision(
        incomingRevision: 9,
        confirmedRevision: 8,
        expectedLocal: saved,
        visibleLocal: visible,
      ),
      isFalse,
    );
    expect(
      canInstallSharedGuestRevision(
        incomingRevision: 9,
        confirmedRevision: 8,
        expectedLocal: visible,
        visibleLocal: visible,
      ),
      isTrue,
    );
  });

}
