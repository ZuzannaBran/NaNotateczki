import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/drift/notes_database_connection.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import '../tool/website_widget_demo.dart';

void main() {
  test('website demo starts with one empty notebook page', () {
    final now = DateTime.utc(2026, 10, 27);
    final notebook = createWebsiteDemoNotebook(now);

    expect(notebook.kind, NotebookKind.notebook);
    expect(notebook.title, 'Pismo i tło strony');
    expect(notebook.pages, hasLength(1));
    expect(notebook.pages.single.inkStrokes, isEmpty);
    expect(notebook.pages.single.textBlocks, isEmpty);
    expect(notebook.pages.single.imageBlocks, isEmpty);
    expect(notebook.createdAt, now);
  });

  test(
    'website demo opens a different database from the regular app',
    () async {
      expect(websiteDemoDatabaseName, isNot('notes.sqlite'));
      expect(websiteDemoDatabaseName, contains('demo'));

      String? openedName;
      final result = await NotesDatabase.open(
        databaseName: websiteDemoDatabaseName,
        connectionOpener: (name) async {
          openedName = name;
          return NotesDatabaseConnection(
            executor: NativeDatabase.memory(),
            freshFile: true,
          );
        },
      );
      addTearDown(result.database.close);

      expect(openedName, websiteDemoDatabaseName);
    },
  );
}
