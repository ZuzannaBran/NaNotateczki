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
  });  test('local account copy renames only matching folder and kind', () {
    final now = DateTime.utc(2026, 11, 2);
    final page = NotePage(
      id: 'local-page',
      title: 'Original',
      textBlocks: [],
      imageBlocks: [],
      inkStrokes: [],
      isBookmarked: false,
    );
    final source = Notebook(
      uid: 'local-id',
      title: 'Notes',
      kind: NotebookKind.notebook,
      folder: 'Classes',
      createdAt: now,
      updatedAt: now,
      pages: [page],
    );
    final titles = [
      source.copyWith(uid: 'server-1'),
      source.copyWith(uid: 'server-2', title: 'Notes (1)'),
      source.copyWith(
        uid: 'other-folder',
        title: 'Notes (2)',
        folder: 'Personal',
      ),
      source.copyWith(
        uid: 'other-kind',
        title: 'Notes (2)',
        kind: NotebookKind.board,
      ),
    ];
    final imported = copyLocalNotebookToAccount(source, titles);
    expect(imported.title, 'Notes (2)');
    expect(imported.folder, source.folder);
    expect(imported.uid, isNot(source.uid));
    expect(imported.pages.single.id, isNot(page.id));
    expect(imported.createdAt, now);
    expect(imported.updatedAt, now);
    expect(source.title, 'Notes');
    final differentFolder = copyLocalNotebookToAccount(
      source.copyWith(folder: 'Elsewhere'),
      titles,
    );
    expect(differentFolder.title, 'Notes');
  });

  test('account copy increments an existing numbered local name', () {
    final time = DateTime.utc(2026, 11, 2);
    final source = Notebook(
      uid: 'local',
      title: 'Work (1)',
      kind: NotebookKind.notebook,
      folder: 'School',
      createdAt: time,
      updatedAt: time,
      pages: [],
    );
    final imported = copyLocalNotebookToAccount(source, [
      source.copyWith(uid: 'remote'),
      source.copyWith(uid: 'remote2', title: 'work (2)'),
    ]);
    expect(imported.title, 'Work (3)');
    expect(imported.uid, isNot(source.uid));
  });

}
