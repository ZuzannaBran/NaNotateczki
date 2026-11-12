import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/active_storage_namespace.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/library_v2_operation_service.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

class _NoNetworkGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('No network in offline test.');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('No network in offline test.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
    ActiveStorageNamespace.activate(StorageNamespace.local());
  });

  test('planner, folder subtree and task changes use the v2 journal',
      () async {
    const user = 'v2-integration-account';
    ActiveStorageNamespace.activate(StorageNamespace.account(user));
    final files = <String, String>{};
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async => files[key] = value;

    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final store = OperationStore(
      database,
      checkpointScope: 'account:$user',
    );
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: store,
      gateway: _NoNetworkGateway(),
      actorId: 'offline-device-a',
      checkpointScope: 'account:$user',
      enableRealtime: false,
      applyRemote: (operation, pending) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    await repository.enableAccountOperations(
      EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
        onCommitted: repository.reportOperationCommit,
      ),
    );

    final journal = LibraryV2OperationService(
      engine: engine,
      accountId: user,
    );
    final library = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    addTearDown(library.dispose);
    library.attachV2LibraryOperations(journal);
    await library.createFolder('School');
    await library.createFolder('Physics', parent: 'School');
    final planner = await library.createPlanner();
    expect((await repository.getNotebook(planner.uid))?.kind.index, 2);
    final task = await library.addPlannerTask(planner.uid);
    await library.updatePlannerTask(
      planner.uid,
      task.id,
      title: 'Lecture',
      completed: true,
    );
    expect(library.plannerTasks(planner.uid).single.completed, isTrue);
    expect((await journal.snapshot()).value['plannerTasks'][planner.uid],
        hasLength(1));

    await library.createFolder('Archive');
    final moved = await library.moveFolderToFolder('School', 'Archive');
    expect(moved, 'Archive/School');
    expect((await journal.snapshot()).folderIdsByPath.keys,
        contains('Archive/School/Physics'));
    expect((await repository.getNotebook(planner.uid))?.folder,
        'Archive/School/Physics');

    await library.deleteItem(planner.uid);
    await library.deleteFolder('Archive');
    expect(await repository.getNotebook(planner.uid), isNull);
    final reconstructed = await journal.snapshot();
    expect(reconstructed.folderIdsByPath, isEmpty);
    expect(reconstructed.value['plannerTasks'], isEmpty);
    final stored = jsonDecode(files['library_folders.json']!);
    expect(stored['plannerTasks'], isEmpty);

    final operations = await store.pending();
    expect(operations.where((op) =>
        op.documentId == OperationEnvelope.libraryDocumentId), isNotEmpty);
    expect(operations.map((op) => op.kind), contains(OperationKind.taskDelete));
    expect(operations.map((op) => op.kind), contains(OperationKind.folderMove));
    expect(await store.isTombstoned(
      OperationEnvelope.libraryDocumentId,
      'task',
      task.id,
    ), isTrue);
  });

  test('writes are rejected when the account namespace changes', () async {
    const user = 'v2-other-account';
    ActiveStorageNamespace.activate(StorageNamespace.local());
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = OperationStore(database);
    final engine = SyncEngine(
      store: store,
      gateway: _NoNetworkGateway(),
      actorId: 'device-x',
      checkpointScope: 'account:$user',
      enableRealtime: false,
      applyRemote: (_, __) async {},
    );
    addTearDown(engine.stop);
    final journal = LibraryV2OperationService(
      engine: engine,
      accountId: user,
    );
    await expectLater(journal.createFolder('Leaked'), throwsStateError);
    expect(await store.pending(), isEmpty);
  });
}
