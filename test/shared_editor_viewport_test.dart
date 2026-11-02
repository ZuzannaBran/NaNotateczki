import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    textStorageReadOverride = (_) async => null;
    textStorageWriteOverride = (_, _) async {};
  });

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('remote shared content preserves local page pan and zoom', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final created = await repository.createNotebook();
    final secondPage = created.pages.single.copyWith(
      id: 'second-page',
      title: 'Second page',
    );
    final notebook = created.copyWith(
      pages: [created.pages.single, secondPage],
    );
    final editor = EditorController(
      repository: repository,
      notebook: notebook,
      saveDebounce: const Duration(milliseconds: 20),
    );
    addTearDown(editor.dispose);
    editor.setCurrentPage(1);
    editor.setViewTransform(pan: const Offset(83, -47), scale: 1.6);
    final remote = notebook.copyWith(
      title: 'Updated by participant B',
      pages: [
        created.pages.single,
        secondPage.copyWith(title: 'Edited from device B'),
      ],
    );

    expect(editor.applyConfirmedRemoteNotebook(remote), isTrue);
    expect(editor.notebook.uid, created.uid);
    expect(editor.notebook.title, 'Updated by participant B');
    expect(editor.currentPage.id, 'second-page');
    expect(editor.currentPage.title, 'Edited from device B');
    expect(editor.currentPageIndex, 1);
    expect(editor.viewPan, const Offset(83, -47));
    expect(editor.viewScale, 1.6);
  });

  test('remote state never replaces a pending local edit', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final editor = EditorController(
      repository: repository,
      notebook: notebook,
      saveDebounce: const Duration(milliseconds: 20),
    );
    addTearDown(editor.dispose);
    editor.addTextBlock(Offset.zero);
    expect(editor.canApplyConfirmedRemoteNotebook, isFalse);
    expect(
      editor.applyConfirmedRemoteNotebook(
        notebook.copyWith(title: 'Remote title'),
      ),
      isFalse,
    );
  });
}
