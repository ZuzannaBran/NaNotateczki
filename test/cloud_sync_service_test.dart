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

  test(
    'remote newer timestamp wins and older remote cannot replace local',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final service = CloudSyncService(repository);
      final original = await repository.createNotebook();
      final older = original.copyWith(
        title: 'Older',
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final newer = original.copyWith(
        title: 'Newer',
        updatedAt: DateTime.utc(2026, 2, 1),
      );

      expect(service.mergeNotebooks([older], [newer]).single.title, 'Newer');
      expect(service.mergeNotebooks([newer], [older]).single.title, 'Newer');
    },
  );

  test(
    'sync merge preserves independent notebooks in newest-first order',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final service = CloudSyncService(repository);
      final first = (await repository.createNotebook()).copyWith(
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final second = (await repository.createNotebook()).copyWith(
        updatedAt: DateTime.utc(2026, 2, 1),
      );

      final merged = service.mergeNotebooks([first], [second]);

      expect(merged, hasLength(2));
      expect(merged.map((notebook) => notebook.uid), [second.uid, first.uid]);
    },
  );

  test('sync merge never duplicates equal notebook identities', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = CloudSyncService(repository);
    final notebook = await repository.createNotebook();

    final merged = service.mergeNotebooks(
      [notebook.copyWith(title: 'Local')],
      [notebook.copyWith(title: 'Cloud')],
    );

    expect(merged, hasLength(1));
    expect(merged.single.uid, notebook.uid);
    expect(merged.single.title, 'Local');
  });
}
