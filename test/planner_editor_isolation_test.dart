import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/page_background.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('planner cannot use editor background preferences', () {
    expect(
      () => backgroundPrefsKeyForKind(NotebookKind.planner),
      throwsUnsupportedError,
    );
    expect(backgroundPrefsKeyForKind(NotebookKind.notebook), 'notebook');
    expect(backgroundPrefsKeyForKind(NotebookKind.board), 'board');
  });

  test('planner cannot instantiate the drawing editor', () async {
    final db = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(db);
    final planner = await repository.createPlanner();
    expect(
      () => EditorController(repository: repository, notebook: planner),
      throwsUnsupportedError,
    );
    await db.close();
  });
}
