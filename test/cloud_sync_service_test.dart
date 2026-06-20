import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local snapshot wins when sync timestamps are equal', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = CloudSyncService(repository);
    final notebook = await repository.createNotebook();
    final local = notebook.copyWith(title: 'Local');
    final cloud = notebook.copyWith(title: 'Cloud');

    final merged = service.mergeNotebooks([local], [cloud]);

    expect(merged.single.title, 'Local');
  });
}
