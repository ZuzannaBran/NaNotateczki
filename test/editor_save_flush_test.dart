import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('flushPendingSaves persists a dirty editor page before exit', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = _notebook();
    expect(await repository.saveNotebook(notebook), isTrue);

    final controller = EditorController(
      repository: repository,
      notebook: notebook,
    );
    addTearDown(controller.dispose);

    controller.addInkStroke(
      const [
        InkPoint(dx: 5, dy: 6, pressure: 0.5),
        InkPoint(dx: 15, dy: 16, pressure: 0.5),
      ],
      toolOverride: DrawingTool.pen,
    );

    await controller.flushPendingSaves();
    await repository.waitForPendingSaves();

    final saved = await repository.getNotebook(notebook.uid);
    expect(saved, isNotNull);
    expect(saved!.pages.single.inkStrokes, hasLength(1));
  });
}

Notebook _notebook() {
  final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);
  return Notebook(
    uid: 'close-guard-notebook',
    title: 'Close guard',
    kind: NotebookKind.notebook,
    folder: 'Notes',
    createdAt: timestamp,
    updatedAt: timestamp,
    pages: [
      NotePage(
        id: 'close-guard-page',
        title: 'Page',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: const [],
        isBookmarked: false,
        indexTabs: const [],
      ),
    ],
  );
}
