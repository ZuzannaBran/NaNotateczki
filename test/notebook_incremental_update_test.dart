import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/text_block.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NotesDatabase database;
  late NotebookRepository repository;

  setUp(() async {
    database = NotesDatabase(NativeDatabase.memory());
    repository = NotebookRepository(database);
    await database.customStatement(
      'CREATE TABLE delete_audit '
      '(table_name TEXT NOT NULL, object_id TEXT NOT NULL)',
    );
    await database.customStatement(
      'CREATE TRIGGER page_delete_audit BEFORE DELETE ON page_rows '
      'BEGIN INSERT INTO delete_audit VALUES (\'page\', OLD.uid); END',
    );
    await database.customStatement(
      'CREATE TRIGGER text_delete_audit BEFORE DELETE ON text_block_rows '
      'BEGIN INSERT INTO delete_audit VALUES (\'text\', OLD.uid); END',
    );
  });

  tearDown(() async {
    await database.close();
  });

  test('metadata/full save preserves existing page records', () async {
    final notebook = await repository.createNotebook();
    final saved = await repository.saveNotebook(
      notebook.copyWith(title: 'New title'),
    );
    expect(saved, isTrue);
    final deletes = await database.customSelect(
      'SELECT * FROM delete_audit',
    ).get();
    expect(deletes, isEmpty);
    final current = await repository.getNotebook(notebook.uid);
    expect(current?.pages.single.id, notebook.pages.single.id);
  });

  test('dirty page edit updates text instead of deleting its row', () async {
    final notebook = await repository.createNotebook();
    final block = TextBlock(
      id: 'text-stable-id',
      text: 'draft',
      position: Offset.zero,
      fontSize: 16,
      color: const Color(0xff000000),
      width: 140,
    );
    final page = notebook.pages.single.copyWith(textBlocks: [block]);
    final withText = notebook.copyWith(pages: [page]);
    expect(await repository.saveNotebook(withText), isTrue);

    await database.customStatement('DELETE FROM delete_audit');
    final edited = withText.copyWith(
      pages: [
        page.copyWith(textBlocks: [block.copyWith(text: 'draft extended')]),
      ],
    );
    expect(
      await repository.saveNotebookPages(edited, {page.id}),
      isTrue,
    );
    final deletes = await database.customSelect(
      'SELECT * FROM delete_audit',
    ).get();
    expect(deletes, isEmpty);
    final current = await repository.getNotebook(notebook.uid);
    expect(current?.pages.single.textBlocks.single.text, 'draft extended');
  });
}
