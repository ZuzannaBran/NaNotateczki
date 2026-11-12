import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';

import 'support/native_test_documents.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('No HTTP calls should occur in this test.');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('No HTTP calls should occur in this test.');
}

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v2 repository routes CRUD exclusively through journal', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    var commits = 0;
    final repository = NotebookRepository(
      database,
      onChanged: (changes) => commits += changes.length,
    );
    final store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'repository-v2-test',
      checkpointScope: 'repository-v2-test',
      enableRealtime: false,
      applyRemote: (operation, pending) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final writer = EditorV2OperationWriter(
      syncEngine: engine,
      projector: projector,
    );
    await repository.enableAccountOperations(writer);

    final notebook = await repository.createNotebook();
    final board = await repository.createBoard();
    expect(await store.pending(), hasLength(4));
    expect((await store.pending()).map((op) => op.kind), [
      OperationKind.documentCreate,
      OperationKind.pageCreate,
      OperationKind.documentCreate,
      OperationKind.pageCreate,
    ]);
    expect(commits, 2);

    await expectLater(
      repository.saveNotebook(
        notebook.copyWith(uid: 'ccab00f6-a8c8-47d6-82bc-de3165a2889d'),
      ),
      throwsA(isA<LegacyProtocolWriteBlocked>()),
    );
    await expectLater(
      repository.saveNotebook(notebook),
      throwsA(isA<LegacyProtocolWriteBlocked>()),
    );
    await expectLater(
      repository.saveNotebookPages(notebook, {notebook.pages.single.id}),
      throwsA(isA<LegacyProtocolWriteBlocked>()),
    );
    final renamed = await repository.updateNotebookMetadata(
      notebook.uid,
      title: 'Renamed through operations',
      folder: 'School',
    );
    expect(renamed?.title, 'Renamed through operations');
    expect(renamed?.folder, 'School');
    expect(
      (await store.pending(documentId: notebook.uid)).last.kind,
      OperationKind.documentSet,
    );
    final pending = (await store.pending()).length;
    await repository.updateNotebookMetadata(
      notebook.uid,
      title: 'Renamed through operations',
      folder: 'School',
    );
    expect(await store.pending(), hasLength(pending));

    await repository.deleteNotebook(board.uid);
    expect(await repository.getNotebook(board.uid), isNull);
    final boardOperations = await store.pending(documentId: board.uid);
    expect(boardOperations.last.kind, OperationKind.documentDelete);
    expect(await store.isTombstoned(board.uid, 'document', board.uid), isTrue);
    expect(commits, 4);
    final planner = await repository.createPlanner();
    expect(planner.kind.index, 2);
    expect((await repository.getNotebook(planner.uid))?.kind.index, 2);
    final movedPlanner = await repository.updateNotebookMetadata(
      planner.uid,
      folder: 'School/Physics',
      title: 'Updated planner',
    );
    expect(movedPlanner?.title, 'Updated planner');
    expect(movedPlanner?.folder, 'School/Physics');
    expect(
      (await repository.getNotebook(planner.uid))?.folder,
      'School/Physics',
    );
    expect(
      (await store.pending(documentId: planner.uid)).last.kind,
      OperationKind.documentSet,
    );
    expect(
      (await store.pending(documentId: planner.uid)).map((op) => op.kind),
      [
        OperationKind.documentCreate,
        OperationKind.pageCreate,
        OperationKind.documentSet,
      ],
    );
    await repository.deleteNotebook(planner.uid);
    expect(await repository.getNotebook(planner.uid), isNull);
    expect(
      (await store.pending(documentId: planner.uid)).last.kind,
      OperationKind.documentDelete,
    );
    expect(
      await store.isTombstoned(planner.uid, 'document', planner.uid),
      isTrue,
    );
    final countAfterDelete = (await store.pending()).length;
    await repository.deleteNotebook(planner.uid);
    expect(await store.pending(), hasLength(countAfterDelete));
    await expectLater(
      writer.writeCreateNotebook(notebook: planner),
      throwsStateError,
    );
    await expectLater(
      writer.writeCreateNotebook(notebook: board),
      throwsStateError,
    );
  });
  test('v2 edit notifies changed pages only after durable commit', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final notifications = <NotebookRepositoryChange>[];
    final repository = NotebookRepository(
      database,
      onChanged: (changes) => notifications.addAll(changes),
    );
    final store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'backup-v2-test',
      checkpointScope: 'backup-v2-test',
      enableRealtime: false,
      applyRemote: (operation, pending) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final writer = EditorV2OperationWriter(
      syncEngine: engine,
      projector: projector,
      onCommitted: repository.reportOperationCommit,
    );
    await repository.enableAccountOperations(writer);

    final notebook = await repository.createNotebook();
    expect(notifications, hasLength(1));
    expect(notifications.single.isFull, isTrue);
    notifications.clear();

    final before = notebook.pages.single;
    final stroke = InkStroke(
      id: 'v2-backup-stroke',
      color: const Color(0xFF112233),
      width: 2,
      tool: DrawingTool.pen,
      points: [const InkPoint(dx: 1, dy: 2, pressure: 0.5)],
    );
    await writer.writePageChange(
      documentId: notebook.uid,
      before: before,
      after: before.copyWith(inkStrokes: [stroke]),
    );
    expect(notifications, hasLength(1));
    expect(notifications.single.uid, notebook.uid);
    expect(notifications.single.pageIds, {before.id});

    notifications.clear();
    await expectLater(
      writer.writeCreateNotebook(notebook: notebook),
      throwsStateError,
    );
    expect(notifications, isEmpty);
    expect(await store.pending(), hasLength(3));
  });

  test('v2 account activation rejects unmigrated documents', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final old = await repository.createNotebook();
    final store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'migration-guard-test',
      checkpointScope: 'migration-guard-test',
      enableRealtime: false,
      applyRemote: (operation, pending) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final writer = EditorV2OperationWriter(
      syncEngine: engine,
      projector: projector,
    );
    await expectLater(
      repository.enableAccountOperations(writer),
      throwsStateError,
    );
    // Failed activation must preserve the old document and its v1 writer.
    expect((await repository.getNotebook(old.uid))!.uid, old.uid);
    expect(await repository.saveNotebook(old), isTrue);
    expect(await store.pending(), isEmpty);
  });
}
