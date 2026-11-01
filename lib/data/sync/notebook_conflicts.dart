import 'package:uuid/uuid.dart';

import '../../features/notebook/domain/notebook.dart';

/// Keeps a conflicting version in its folder without reusing object IDs.
Notebook numberedNotebookCopy(Notebook source, Iterable<Notebook> existing) {
  final titles = existing
      .where((note) => note.folder == source.folder)
      .map((note) => note.title)
      .toSet();
  final stem = source.title.replaceFirst(RegExp(r' \(\d+\)$'), '');
  var number = 1;
  while (titles.contains('$stem ($number)')) {
    number++;
  }
  const uuid = Uuid();
  final now = DateTime.now().toUtc();
  return source.copyWith(
    uid: uuid.v4(),
    title: '$stem ($number)',
    createdAt: now,
    updatedAt: now,
    pages: [
      for (final page in source.pages)
        page.copyWith(
          id: uuid.v4(),
          textBlocks: [
            for (final block in page.textBlocks) block.copyWith(id: uuid.v4()),
          ],
          imageBlocks: [
            for (final block in page.imageBlocks)
              block.copyWith(
                id: uuid.v4(),
                path: block.bytes?.isNotEmpty == true ? '' : block.path,
              ),
          ],
          inkStrokes: [
            for (final stroke in page.inkStrokes)
              stroke.copyWith(id: uuid.v4()),
          ],
        ),
    ],
  );
}
