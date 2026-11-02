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

/// Creates a separate account document from a local source without
/// overwriting an existing title in the same folder and notebook kind.
/// The caller is responsible for durable, idempotent import checkpoints.
Notebook copyLocalNotebookToAccount(
  Notebook source,
  Iterable<Notebook> existing,
) {
  final reserved = existing
      .where((item) => item.folder == source.folder && item.kind == source.kind)
      .map((item) => item.title.trim().toLowerCase())
      .toSet();
  final originalTitle = source.title.trim();
  var uniqueTitle = originalTitle;
  if (reserved.contains(uniqueTitle.toLowerCase())) {
    final stem = originalTitle.replaceFirst(RegExp(r' \(\d+\)$'), '');
    var number = 1;
    while (reserved.contains('$stem ($number)'.toLowerCase())) {
      number++;
    }
    uniqueTitle = '$stem ($number)';
  }
  final copy = numberedNotebookCopy(source, const <Notebook>[]);
  return copy.copyWith(
    title: uniqueTitle,
    createdAt: source.createdAt,
    updatedAt: source.updatedAt,
  );
}
