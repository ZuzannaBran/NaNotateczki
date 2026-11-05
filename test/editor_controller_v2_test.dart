import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/text_block.dart';

import 'support/native_test_documents.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('No network in this regression.');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('No network in this regression.');
}

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('opt-in editor uses v2 outbox but never the snapshot writer',
      () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    var repositoryWrites = 0;
    final repository = NotebookRepository(
      database,
      onChanged: (changes) => repositoryWrites += changes.length,
    );
    final notebook = await repository.createNotebook();
    repositoryWrites = 0;
    final store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'v2-editor',
      checkpointScope: 'v2-editor-test',
      enableRealtime: false,
      applyRemote: (operation, pending) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final controller = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      ),
    );
    addTearDown(controller.dispose);
    await expectLater(
      repository.saveNotebook(notebook, preserveMetadata: true),
      throwsStateError,
    );
    await expectLater(
      repository.saveNotebookPages(
        notebook,
        {notebook.pages.single.id},
      ),
      throwsStateError,
    );
    await expectLater(
      repository.updateNotebookMetadata(notebook.uid, title: 'legacy'),
      throwsStateError,
    );
    await expectLater(
      repository.deleteNotebook(notebook.uid),
      throwsStateError,
    );
    expect(
      () => EditorController(
        repository: repository,
        notebook: notebook,
        operationWriter: EditorV2OperationWriter(
          syncEngine: engine,
          projector: projector,
        ),
      ),
      throwsStateError,
    );

    controller.addInkStroke(const [
      InkPoint(dx: 4, dy: 5, pressure: 0.6),
    ]);
    await controller.flushPendingSaves();
    final created = await store.pending();
    expect(created, hasLength(1));
    expect(created.single.kind, OperationKind.strokeCreate);
    expect(repositoryWrites, 0);
    expect(
      (await repository.getNotebook(notebook.uid))
          ?.pages.single.inkStrokes,
      hasLength(1),
    );
    expect(controller.canUndo, isTrue);
    controller.undo();
    await controller.flushPendingSaves();
    expect((await store.pending()).last.kind, OperationKind.objectDelete);
    expect(
      (await repository.getNotebook(notebook.uid))!
          .pages.single.inkStrokes,
      isEmpty,
    );
    expect(controller.canRedo, isTrue);
    controller.redo();
    await controller.flushPendingSaves();
    final restored = (await repository.getNotebook(notebook.uid))!
        .pages.single.inkStrokes.single;
    // Redo is a fresh insert: the old UID remains tombstoned.
    expect(restored.id, isNot(created.single.objectId));
    expect((await store.pending()).last.kind, OperationKind.strokeCreate);
    expect(repositoryWrites, 0);

    controller.addPage();
    await controller.flushPendingSaves();
    final saved = (await repository.getNotebook(notebook.uid))!;
    expect(saved.pages, hasLength(2));
    expect(saved.pages.first.inkStrokes, hasLength(1));
    expect((await store.pending()).last.kind, OperationKind.pageCreate);
    controller.deleteLastPage();
    await controller.flushPendingSaves();
    expect(
      (await repository.getNotebook(notebook.uid))?.pages,
      hasLength(1),
    );
    expect((await store.pending()).last.kind, OperationKind.pageDelete);
    controller.undo();
    await controller.flushPendingSaves();
    final pageRestored = (await repository.getNotebook(notebook.uid))!;
    expect(pageRestored.pages, hasLength(2));
    expect(pageRestored.pages.last.id, isNot(saved.pages.last.id));
    expect((await store.pending()).last.kind, OperationKind.pageCreate);
    controller.redo();
    await controller.flushPendingSaves();
    expect((await repository.getNotebook(notebook.uid))!.pages, hasLength(1));
    expect((await store.pending()).last.kind, OperationKind.pageDelete);
    expect(repositoryWrites, 0);
  });

  test('remote text and image patches keep their layer order', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: OperationStore(database),
      gateway: _OfflineGateway(),
      actorId: 'remote-layer-test',
      checkpointScope: 'remote-layer-test',
      enableRealtime: false,
      applyRemote: (_, __) async {},
    );
    addTearDown(engine.stop);
    final controller = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      ),
    );
    addTearDown(controller.dispose);
    final id = notebook.pages.single.id;
    TextBlock text(String id, String contents) => TextBlock(
      id: id,
      text: contents,
      position: Offset.zero,
      width: 100,
      fontSize: 18,
      color: const Color(0xFF112233),
    );
    ImageBlock image(String id) => ImageBlock(
      id: id,
      path: '',
      ocrText: '',
      position: Offset.zero,
      width: 100,
      height: 80,
    );

    expect(controller.applyConfirmedShareObjectPatch(
      pageId: id,
      objectId: 'text-a',
      text: text('text-a', 'A'),
      sortIndex: 0,
    ), isTrue);
    expect(controller.applyConfirmedShareObjectPatch(
      pageId: id,
      objectId: 'text-b',
      text: text('text-b', 'B'),
      sortIndex: 1,
    ), isTrue);
    expect(controller.applyConfirmedShareObjectPatch(
      pageId: id,
      objectId: 'text-a',
      text: text('text-a', 'Changed'),
      sortIndex: 0,
    ), isTrue);
    expect(
      controller.currentPage.textBlocks.map((e) => e.id).toList(),
      ['text-a', 'text-b'],
    );

    expect(controller.applyConfirmedShareObjectPatch(
      pageId: id,
      objectId: 'image-a',
      image: image('image-a'),
      sortIndex: 0,
    ), isTrue);
    expect(controller.applyConfirmedShareObjectPatch(
      pageId: id,
      objectId: 'image-b',
      image: image('image-b'),
      sortIndex: 1,
    ), isTrue);
    expect(controller.applyConfirmedShareObjectPatch(
      pageId: id,
      objectId: 'image-a',
      image: image('image-a'),
      sortIndex: 1,
    ), isTrue);
    expect(
      controller.currentPage.imageBlocks.map((e) => e.id).toList(),
      ['image-b', 'image-a'],
    );
  });

  test('opt-in controller rejects a projection from a different SQLite',
      () async {
    final first = NotesDatabase(NativeDatabase.memory());
    final second = NotesDatabase(NativeDatabase.memory());
    addTearDown(first.close);
    addTearDown(second.close);
    final repository = NotebookRepository(first);
    final notebook = await repository.createNotebook();
    final engine = SyncEngine(
      store: OperationStore(second),
      gateway: _OfflineGateway(),
      actorId: 'wrong-database',
      checkpointScope: 'wrong-namespace',
      enableRealtime: false,
      applyRemote: (_, __) async {},
    );
    addTearDown(engine.stop);
    final writer = EditorV2OperationWriter(
      syncEngine: engine,
      projector: EditorSqliteProjector(second),
    );
    expect(
      () => EditorController(
        repository: repository,
        notebook: notebook,
        operationWriter: writer,
      ),
      throwsArgumentError,
    );
  });
  test('rapid independent strokes have separate v2 Undo boundaries',
      () async {
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = NotebookRepository(db);
    final notebook = await repo.createNotebook();
    final store = OperationStore(db);
    final projector = EditorSqliteProjector(db);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'gesture-peer',
      checkpointScope: 'gesture-test',
      enableRealtime: false,
      applyRemote: (op, _) => projector.apply(op),
    );
    addTearDown(engine.stop);
    final editor = EditorController(
      repository: repo,
      notebook: notebook,
      operationWriter: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      ),
    );
    addTearDown(editor.dispose);
    editor.addInkStroke(const [InkPoint(dx: 1, dy: 2, pressure: 0.5)]);
    editor.addInkStroke(const [InkPoint(dx: 3, dy: 4, pressure: 0.6)]);
    await editor.flushPendingSaves();
    expect((await store.pending()).map((e) => e.kind), [
      OperationKind.strokeCreate,
      OperationKind.strokeCreate,
    ]);
    editor.undo();
    await editor.flushPendingSaves();
    expect(
      (await repo.getNotebook(notebook.uid))!.pages.single.inkStrokes,
      hasLength(1),
    );
    editor.redo();
    await editor.flushPendingSaves();
    expect(
      (await repo.getNotebook(notebook.uid))!.pages.single.inkStrokes,
      hasLength(2),
    );
  });

}
