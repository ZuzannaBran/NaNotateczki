import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/drift/notes_database_connection.dart';

void main() {
  test(
    'database open relocates image paths after data directory migration',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('image-path-test-');
      addTearDown(() => sandbox.delete(recursive: true));
      final databaseFile = File('${sandbox.path}/notes.sqlite');
      final legacyImages = '${sandbox.path}/documents/images';
      final currentImages = '${sandbox.path}/support/data/images';

      final initial = NotesDatabase(NativeDatabase(databaseFile));
      final now = DateTime.utc(2026, 1, 1);
      await initial
          .into(initial.notebookRows)
          .insert(
            NotebookRowsCompanion.insert(
              uid: 'notebook',
              title: 'Test',
              kindIndex: 0,
              folder: '',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await initial
          .into(initial.pageRows)
          .insert(
            PageRowsCompanion.insert(
              uid: 'page',
              notebookUid: 'notebook',
              pageIndex: 0,
              title: '',
              isBookmarked: false,
            ),
          );
      await initial
          .into(initial.imageBlockRows)
          .insert(
            ImageBlockRowsCompanion.insert(
              uid: 'image',
              pageUid: 'page',
              path: '$legacyImages/nested/example.png',
              ocrText: '',
              width: 100,
              height: 100,
              rotation: 0,
              dx: 0,
              dy: 0,
              cropLeft: 0,
              cropTop: 0,
              cropRight: 1,
              cropBottom: 1,
              sortIndex: 0,
            ),
          );
      await initial.close();

      final result = await NotesDatabase.open(
        connectionOpener: (_) async => NotesDatabaseConnection(
          executor: NativeDatabase(databaseFile),
          freshFile: false,
          legacyImageDirectory: legacyImages,
          imageDirectory: currentImages,
        ),
      );
      addTearDown(result.database.close);

      final image = await result.database
          .select(result.database.imageBlockRows)
          .getSingle();
      expect(image.path, '$currentImages/nested/example.png');
    },
  );
}
