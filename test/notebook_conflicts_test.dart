import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/notebook_conflicts.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/text_block.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';

void main() {
  test('numbered copies preserve content but never reuse contained IDs', () {
    final now = DateTime.utc(2026, 11, 1);
    final source = Notebook(
      uid: 'source',
      title: 'Course',
      kind: NotebookKind.notebook,
      folder: 'School',
      createdAt: now,
      updatedAt: now,
      pages: [
        NotePage(
          id: 'page',
          title: 'Page',
          isBookmarked: true,
          textBlocks: [
            TextBlock(
              id: 'text',
              text: 'Keep me',
              position: Offset.zero,
              fontSize: 14,
              color: const Color(0xff000000),
              width: 100,
            ),
          ],
          imageBlocks: [
            ImageBlock(
              id: 'image',
              path: '/old/device.png',
              ocrText: '',
              position: Offset.zero,
              width: 20,
              height: 20,
              bytes: Uint8List.fromList([1, 2, 3]),
            ),
          ],
          inkStrokes: [
            InkStroke(
              id: 'stroke',
              points: [],
              color: const Color(0xff000000),
              width: 1,
              tool: DrawingTool.pen,
            ),
          ],
        ),
      ],
    );
    final copy = numberedNotebookCopy(source, [
      source,
      source.copyWith(uid: 'occupied', title: 'Course (1)'),
      source.copyWith(
        uid: 'other-folder',
        title: 'Course (2)',
        folder: 'Elsewhere',
      ),
    ]);

    expect(copy.title, 'Course (2)');
    expect(copy.folder, source.folder);
    expect(copy.uid, isNot(source.uid));
    final page = copy.pages.single;
    expect(page.id, isNot(source.pages.single.id));
    expect(page.isBookmarked, isTrue);
    expect(page.textBlocks.single.id, isNot('text'));
    expect(page.textBlocks.single.text, 'Keep me');
    expect(page.imageBlocks.single.id, isNot('image'));
    expect(page.imageBlocks.single.bytes, [1, 2, 3]);
    expect(page.imageBlocks.single.path, '');
    expect(page.inkStrokes.single.id, isNot('stroke'));
    expect(source.pages.single.imageBlocks.single.path, '/old/device.png');
    expect(source.title, 'Course');
  });
}
