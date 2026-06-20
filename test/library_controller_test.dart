import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load failure preserves previously visible notebooks', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(
      database,
      readErrorHandler: (_, _, _) {},
    );
    final notebook = await repository.createNotebook();
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    )..items = [notebook];
    await database.close();

    await controller.loadItems();

    expect(controller.items, [notebook]);
    expect(controller.loadError, isNotNull);
    expect(controller.isLoading, isFalse);
  });
}
