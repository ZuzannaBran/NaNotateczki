import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/notebook.dart';

class _DelayedRepository extends NotebookRepository {
  _DelayedRepository(super.database);

  final completer = Completer<List<Notebook>>();

  @override
  Future<List<Notebook>> fetchNotebooks() => completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('closing library during asynchronous loading never notifies dispose',
      () async {
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = _DelayedRepository(db);
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );

    final loading = controller.loadItems();
    expect(controller.isLoading, isTrue);
    controller.dispose();
    repository.completer.complete(<Notebook>[]);
    await loading;

    expect(controller.isLoading, isFalse);
  });
}
