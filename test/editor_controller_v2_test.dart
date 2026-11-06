import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_history_checkpoint.dart';
import 'package:program/data/sync/editor_history_notebook_codec.dart';
import 'package:program/data/sync/editor_history_store.dart';
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
import 'package:program/features/notebook/domain/notebook.dart';
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

/// Forces the real controller transaction through its history-size fallback.
class _OversizedHistoryCodec extends EditorHistoryNotebookCodec {
  _OversizedHistoryCodec(super.projector);

  @override
  Future<Map<String, dynamic>> encode(Notebook notebook) async {
    throw const EditorHistoryBudgetExceeded(
      'History notebook exceeds its byte budget.',
    );
  }
}

class _GatedHistoryCodec extends EditorHistoryNotebookCodec {
  _GatedHistoryCodec(super.projector, this.entered, this.release);

  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<Notebook> decode(
    Map<String, dynamic> value, {
    required String documentId,
  }) async {
    entered.complete();
    await release.future;
    return super.decode(value, documentId: documentId);
  }
}

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final duringDecode in [false, true]) {
    test(
      'remote commit invalidates page Undo (during decode: $duringDecode)',
      () async {
        final database = NotesDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final repository = NotebookRepository(database);
        final notebook = await repository.createNotebook();
        final projector = EditorSqliteProjector(database);
        final store = OperationStore(database);
        final engine = SyncEngine(
          store: store,
          gateway: _OfflineGateway(),
          actorId: 'inverse-race-peer',
          checkpointScope: 'inverse-race-account',
          enableRealtime: false,
          applyRemote: (operation, _) => projector.apply(operation),
        );
        addTearDown(engine.stop);
        final writer = EditorV2OperationWriter(
          syncEngine: engine,
          projector: projector,
        );
        final first = EditorController(
          repository: repository,
          notebook: notebook,
          operationWriter: writer,
        );
        await first.historyReady;
        await first.preferencesReady;
        first.addPage();
        await first.flushPendingSaves();
        final created = await store.pending();
        expect(created.last.kind, OperationKind.pageCreate);
        final pageId = first.pages.last.id;
        for (var i = 0; i < created.length; i++) {
          await store.acknowledge(
            created[i].operationId,
            serverSequence: i + 1,
          );
        }
        first.dispose();
        final entered = Completer<void>();
        final release = Completer<void>();
        final editor = EditorController(
          repository: repository,
          notebook: (await repository.getNotebook(notebook.uid))!,
          operationWriter: writer,
          historyCodec: duringDecode
              ? _GatedHistoryCodec(projector, entered, release)
              : null,
        );
        addTearDown(editor.dispose);
        await editor.historyReady;
        await editor.preferencesReady;
        expect(editor.canUndo, isTrue);
        final remote = OperationEnvelope(
          operationId: '00000000-0000-4000-8000-000000000123',
          actorId: 'other-device',
          actorSeq: 1,
          logicalClock: created.last.logicalClock + 1,
          dependencies: [created.last.operationId],
          documentId: notebook.uid,
          pageId: pageId,
          objectId: 'other-device-stroke',
          kind: OperationKind.strokeCreate,
          payload: {
            'value': {
              'objectType': 'stroke',
              'colorValue': 0xFF123456,
              'width': 2,
              'toolIndex': 0,
              'sortIndex': 0,
              'points': [
                [1, 2, 0.5],
              ],
            },
          },
        );
        Future<void> commitRemote() async {
          await store.applyRemote(
            remote,
            serverSequence: 100,
            apply: () => projector.apply(remote),
          );
        }

        if (duringDecode) {
          editor.undo();
          await entered.future;
          try {
            await commitRemote();
          } finally {
            release.complete();
          }
        } else {
          await commitRemote();
          editor.undo();
        }
        await editor.flushPendingSaves();
        expect(editor.canUndo, isFalse);
        expect(editor.canRedo, isFalse);
        expect(await store.pending(), isEmpty);
        expect(await store.isTombstoned(notebook.uid, 'page', pageId), isFalse);
        final durable = (await repository.getNotebook(notebook.uid))!;
        expect(durable.pages, hasLength(2));
        expect(durable.pages.last.inkStrokes.single.id, remote.objectId);
        expect(editor.pages, hasLength(2));
        expect(
          editor.applyConfirmedV2PagePatch(
            pageId: pageId,
            page: durable.pages.last,
          ),
          isTrue,
        );
        editor.addInkStroke(const [InkPoint(dx: 8, dy: 9, pressure: 0.6)]);
        await editor.flushPendingSaves();
        expect(
          (await store.pending()).first.actorSeq,
          created.last.actorSeq + 1,
        );
        expect(editor.canUndo, isTrue);
        editor.undo();
        await editor.flushPendingSaves();
        expect(
          (await repository.getNotebook(
            notebook.uid,
          ))!.pages.last.inkStrokes.single.id,
          remote.objectId,
        );
        expect(editor.pages, hasLength(2));
      },
    );
  }

  test(
    'shared engine keeps controller history scoped to each document actor',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final first = await repository.createNotebook();
      final second = await repository.createNotebook();
      final projector = EditorSqliteProjector(database);
      final engine = SyncEngine(
        store: OperationStore(database),
        gateway: _OfflineGateway(),
        actorId: 'two-document-seed',
        checkpointScope: 'two-document-account',
        enableRealtime: false,
        applyRemote: (operation, _) => projector.apply(operation),
      );
      addTearDown(engine.stop);
      final writer = EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      );
      final one = EditorController(
        repository: repository,
        notebook: first,
        operationWriter: writer,
      );
      final two = EditorController(
        repository: repository,
        notebook: second,
        operationWriter: writer,
      );
      addTearDown(one.dispose);
      addTearDown(two.dispose);
      await Future.wait([one.historyReady, two.historyReady]);
      one.addInkStroke(const [InkPoint(dx: 1, dy: 2, pressure: 0.5)]);
      two.addInkStroke(const [InkPoint(dx: 3, dy: 4, pressure: 0.7)]);
      await Future.wait([one.flushPendingSaves(), two.flushPendingSaves()]);
      final store = EditorHistoryStore(engine.store);
      final actorOne = engine.actorIdForDocument(first.uid);
      final actorTwo = engine.actorIdForDocument(second.uid);
      expect(actorOne, isNot(actorTwo));
      final historyOne = (await store.load(
        documentId: first.uid,
        ownerId: actorOne,
      ))!;
      final historyTwo = (await store.load(
        documentId: second.uid,
        ownerId: actorTwo,
      ))!;
      expect(historyOne.undo, hasLength(1));
      expect(historyTwo.undo, hasLength(1));
      expect(historyOne.undo.single.after['uid'], first.uid);
      expect(historyTwo.undo.single.after['uid'], second.uid);
      expect(
        await store.load(documentId: first.uid, ownerId: actorTwo),
        isNull,
      );
      expect(
        await store.load(documentId: second.uid, ownerId: actorOne),
        isNull,
      );
      expect((await engine.store.pending()).map((op) => op.actorSeq), [1, 1]);
    },
  );

  test('remote v2 patch waits for history recovery to settle', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: OperationStore(database),
      gateway: _OfflineGateway(),
      actorId: 'history-recovery-race',
      checkpointScope: 'history-recovery-race',
      enableRealtime: false,
      applyRemote: (operation, _) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final entered = Completer<void>();
    final release = Completer<void>();
    final transaction = database.transaction(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final controller = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      ),
    );
    addTearDown(controller.dispose);
    final page = notebook.pages.single;
    expect(controller.canApplyConfirmedRemoteNotebook, isFalse);
    expect(
      controller.applyConfirmedV2PagePatch(pageId: page.id, page: page),
      isFalse,
    );
    release.complete();
    await transaction;
    await controller.historyReady;
    expect(controller.canApplyConfirmedRemoteNotebook, isTrue);
    expect(
      controller.applyConfirmedV2PagePatch(pageId: page.id, page: page),
      isTrue,
    );
    expect(await engine.store.pending(), isEmpty);
  });

  test('corrupt recovered Undo checkpoint refuses remote patches', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final projector = EditorSqliteProjector(database);
    final store = OperationStore(database);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'corrupt-history-actor',
      checkpointScope: 'corrupt-history',
      enableRealtime: false,
      applyRemote: (operation, _) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final writer = EditorV2OperationWriter(
      syncEngine: engine,
      projector: projector,
    );
    final first = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: writer,
    );
    await first.historyReady;
    first.addInkStroke(const [InkPoint(dx: 9, dy: 7, pressure: 0.6)]);
    await first.flushPendingSaves();
    expect(first.canUndo, isTrue);
    first.dispose();

    await database.customStatement(
      'UPDATE editor_history SET checksum_sha256 = ? '
      'WHERE document_id = ? AND owner_id = ?',
      ['0' * 64, notebook.uid, engine.actorIdForDocument(notebook.uid)],
    );
    final stored = (await repository.getNotebook(notebook.uid))!;
    final second = EditorController(
      repository: repository,
      notebook: stored,
      operationWriter: writer,
    );
    addTearDown(second.dispose);
    await second.historyReady;
    expect(second.canApplyConfirmedRemoteNotebook, isFalse);
    expect(
      second.applyConfirmedV2PagePatch(
        pageId: stored.pages.single.id,
        page: stored.pages.single,
      ),
      isFalse,
    );
    await expectLater(
      second.flushPendingSaves(),
      throwsA(isA<DataIntegrityProtectionException>()),
    );
    expect(await store.pending(), hasLength(1));
    expect(
      (await repository.getNotebook(notebook.uid))!.pages.single.inkStrokes,
      hasLength(1),
    );
  });

  test('history size limit preserves the v2 gesture and its outbox', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'oversized-history-actor',
      checkpointScope: 'oversized-history',
      enableRealtime: false,
      applyRemote: (operation, _) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final controller = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      ),
      historyCodec: _OversizedHistoryCodec(projector),
    );
    addTearDown(controller.dispose);
    await controller.historyReady;

    controller.addInkStroke(const [InkPoint(dx: 4, dy: 9, pressure: 0.5)]);
    await controller.flushPendingSaves();
    expect(controller.canUndo, isFalse);
    expect(controller.canRedo, isFalse);
    expect(controller.currentPage.inkStrokes, hasLength(1));
    expect(
      (await repository.getNotebook(notebook.uid))!.pages.single.inkStrokes,
      hasLength(1),
    );
    final committed = await store.pending();
    expect(committed, hasLength(1));
    expect(committed.single.kind, OperationKind.strokeCreate);
    final checkpoint = await EditorHistoryStore(store).load(
      documentId: notebook.uid,
      ownerId: engine.actorIdForDocument(notebook.uid),
    );
    expect(checkpoint, isNotNull);
    expect(checkpoint!.headOperationId, committed.last.operationId);
    expect(checkpoint.undo, isEmpty);
    expect(checkpoint.redo, isEmpty);
  });

  test(
    'controller recovers Undo/Redo from its durable actor checkpoint',
    () async {
      final directory = await Directory.systemTemp.createTemp('nn-v2-ui-undo-');
      final file = File('${directory.path}/notes.sqlite');
      try {
        final firstDb = NotesDatabase(NativeDatabase(file));
        final firstRepo = NotebookRepository(firstDb);
        final notebook = await firstRepo.createNotebook();
        final firstProjector = EditorSqliteProjector(firstDb);
        final firstEngine = SyncEngine(
          store: OperationStore(firstDb),
          gateway: _OfflineGateway(),
          actorId: 'persisted-editor-actor',
          checkpointScope: 'persisted-editor-actor',
          enableRealtime: false,
          applyRemote: (operation, _) => firstProjector.apply(operation),
        );
        final first = EditorController(
          repository: firstRepo,
          notebook: notebook,
          operationWriter: EditorV2OperationWriter(
            syncEngine: firstEngine,
            projector: firstProjector,
          ),
        );
        await first.historyReady;
        await firstDb.customStatement(
          "CREATE TRIGGER reject_editor_history BEFORE INSERT ON editor_history "
          "BEGIN SELECT RAISE(ABORT, 'injected history failure'); END",
        );
        first.addInkStroke(const [InkPoint(dx: 2, dy: 3, pressure: 0.7)]);
        expect(first.canUndo, isTrue);
        final revisionBeforeFailure = first.historyRevision.value;
        await expectLater(
          first.flushPendingSaves(),
          throwsA(isA<DataIntegrityProtectionException>()),
        );
        expect(await firstEngine.store.pending(), isEmpty);
        expect(first.currentPage.inkStrokes, hasLength(1));
        expect(first.canUndo, isFalse);
        expect(first.historyRevision.value, greaterThan(revisionBeforeFailure));
        final revisionAfterFailure = first.historyRevision.value;
        await firstDb.customStatement('DROP TRIGGER reject_editor_history');
        await first.flushPendingSaves();
        final originalId = first.currentPage.inkStrokes.single.id;
        expect(first.canUndo, isTrue);
        expect(first.historyRevision.value, greaterThan(revisionAfterFailure));
        final firstHistory = EditorHistoryStore(firstEngine.store);
        final checkpoint = await firstHistory.load(
          documentId: notebook.uid,
          ownerId: firstEngine.actorIdForDocument(notebook.uid),
        );
        expect(checkpoint!.undo, hasLength(1));
        final pending = await firstEngine.store.pending();
        expect(checkpoint.ownerId, pending.single.actorId);
        expect(checkpoint.ownerId, isNot(firstEngine.actorId));
        expect(
          await firstHistory.load(
            documentId: notebook.uid,
            ownerId: firstEngine.actorId,
          ),
          isNull,
        );
        first.dispose();
        await firstEngine.stop();
        await firstDb.close();

        final secondDb = NotesDatabase(NativeDatabase(file));
        final secondRepo = NotebookRepository(secondDb);
        final secondProjector = EditorSqliteProjector(secondDb);
        final secondEngine = SyncEngine(
          store: OperationStore(secondDb),
          gateway: _OfflineGateway(),
          actorId: 'persisted-editor-actor',
          checkpointScope: 'persisted-editor-actor',
          enableRealtime: false,
          applyRemote: (operation, _) => secondProjector.apply(operation),
        );
        final second = EditorController(
          repository: secondRepo,
          notebook: (await secondRepo.getNotebook(notebook.uid))!,
          operationWriter: EditorV2OperationWriter(
            syncEngine: secondEngine,
            projector: secondProjector,
          ),
        );
        await second.historyReady;
        expect(second.canUndo, isTrue);
        second.undo();
        await second.flushPendingSaves();
        expect(second.currentPage.inkStrokes, isEmpty);
        expect(second.canRedo, isTrue);
        second.redo();
        await second.flushPendingSaves();
        expect(second.currentPage.inkStrokes, hasLength(1));
        expect(second.currentPage.inkStrokes.single.id, isNot(originalId));
        expect(
          (await EditorHistoryStore(secondEngine.store).load(
            documentId: notebook.uid,
            ownerId: secondEngine.actorIdForDocument(notebook.uid),
          ))!.undo,
          hasLength(1),
        );
        second.dispose();
        await secondEngine.stop();
        await secondDb.close();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('rich Quill Undo and Redo survive a SQLite editor restart', () async {
    final directory = await Directory.systemTemp.createTemp('nn-v2-quill-');
    final file = File('${directory.path}/notes.sqlite');
    try {
      final firstDb = NotesDatabase(NativeDatabase(file));
      final firstRepo = NotebookRepository(firstDb);
      final notebook = await firstRepo.createNotebook();
      final firstProjector = EditorSqliteProjector(firstDb);
      final firstEngine = SyncEngine(
        store: OperationStore(firstDb),
        gateway: _OfflineGateway(),
        actorId: 'durable-rich-text',
        checkpointScope: 'durable-rich-text',
        enableRealtime: false,
        applyRemote: (operation, _) => firstProjector.apply(operation),
      );
      final firstWriter = EditorV2OperationWriter(
        syncEngine: firstEngine,
        projector: firstProjector,
      );
      final originalDelta = jsonEncode([
        {
          'insert': 'Bold',
          'attributes': {'bold': true},
        },
        {'insert': ' and normal\n'},
      ]);
      final editedDelta = jsonEncode([
        {
          'insert': 'Bold',
          'attributes': {'bold': true},
        },
        {
          'insert': ' and italic',
          'attributes': {'italic': true},
        },
        {'insert': '!\n'},
      ]);
      final initial = TextBlock(
        id: 'rich-restart-block',
        text: 'Bold and normal',
        deltaJson: originalDelta,
        position: Offset.zero,
        fontSize: 18,
        color: const Color(0xFF123456),
        width: 220,
      );
      await firstWriter.writePageChange(
        documentId: notebook.uid,
        before: notebook.pages.single,
        after: notebook.pages.single.copyWith(textBlocks: [initial]),
      );
      final before = (await firstRepo.getNotebook(notebook.uid))!;
      final beforeDelta = before.pages.single.textBlocks.single.deltaJson;
      final first = EditorController(
        repository: firstRepo,
        notebook: before,
        operationWriter: firstWriter,
      );
      await first.historyReady;
      first.setActiveTextBlock(initial.id, null);
      first.updateTextBlockContent(
        first.currentPage.textBlocks.single,
        plainText: 'Bold and italic!',
        deltaJson: editedDelta,
      );
      first.setActiveTextBlock(null, null);
      await first.flushPendingSaves();
      expect(first.canUndo, isTrue);
      final after = (await firstRepo.getNotebook(notebook.uid))!;
      final editedPersistedDelta =
          after.pages.single.textBlocks.single.deltaJson;
      expect(after.pages.single.textBlocks.single.text, 'Bold and italic!');
      expect(editedPersistedDelta, isNot(beforeDelta));
      first.dispose();
      await firstEngine.stop();
      await firstDb.close();

      final secondDb = NotesDatabase(NativeDatabase(file));
      final secondRepo = NotebookRepository(secondDb);
      final secondProjector = EditorSqliteProjector(secondDb);
      final secondEngine = SyncEngine(
        store: OperationStore(secondDb),
        gateway: _OfflineGateway(),
        actorId: 'durable-rich-text',
        checkpointScope: 'durable-rich-text',
        enableRealtime: false,
        applyRemote: (operation, _) => secondProjector.apply(operation),
      );
      final second = EditorController(
        repository: secondRepo,
        notebook: (await secondRepo.getNotebook(notebook.uid))!,
        operationWriter: EditorV2OperationWriter(
          syncEngine: secondEngine,
          projector: secondProjector,
        ),
      );
      await second.historyReady;
      expect(second.canUndo, isTrue);
      second.undo();
      await second.flushPendingSaves();
      expect(second.currentPage.textBlocks.single.text, 'Bold and normal');
      expect(second.currentPage.textBlocks.single.deltaJson, beforeDelta);
      expect(
        (await secondRepo.getNotebook(
          notebook.uid,
        ))!.pages.single.textBlocks.single.deltaJson,
        beforeDelta,
      );
      expect(second.canRedo, isTrue);
      second.redo();
      await second.flushPendingSaves();
      expect(second.currentPage.textBlocks.single.text, 'Bold and italic!');
      expect(
        (await secondRepo.getNotebook(
          notebook.uid,
        ))!.pages.single.textBlocks.single.deltaJson,
        editedPersistedDelta,
      );
      expect(second.canUndo, isTrue);
      second.dispose();
      await secondEngine.stop();
      await secondDb.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('opt-in editor uses v2 outbox but never the snapshot writer', () async {
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
      repository.saveNotebookPages(notebook, {notebook.pages.single.id}),
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

    controller.addInkStroke(const [InkPoint(dx: 4, dy: 5, pressure: 0.6)]);
    await controller.flushPendingSaves();
    final created = await store.pending();
    expect(created, hasLength(1));
    expect(created.single.kind, OperationKind.strokeCreate);
    expect(repositoryWrites, 0);
    expect(
      (await repository.getNotebook(notebook.uid))?.pages.single.inkStrokes,
      hasLength(1),
    );
    expect(controller.canUndo, isTrue);
    controller.undo();
    await controller.flushPendingSaves();
    final inverse = (await store.pending()).last;
    expect(inverse.kind, OperationKind.objectDelete);
    expect(inverse.revertsOperationId, created.single.operationId);
    expect(inverse.dependencies, contains(created.single.operationId));
    expect(
      (await repository.getNotebook(notebook.uid))!.pages.single.inkStrokes,
      isEmpty,
    );
    expect(controller.canRedo, isTrue);
    controller.redo();
    await controller.flushPendingSaves();
    final restored = (await repository.getNotebook(
      notebook.uid,
    ))!.pages.single.inkStrokes.single;
    // Redo is a fresh insert: the old UID remains tombstoned.
    expect(restored.id, isNot(created.single.objectId));
    final replay = (await store.pending()).last;
    expect(replay.kind, OperationKind.strokeCreate);
    expect(replay.revertsOperationId, inverse.operationId);
    expect(replay.dependencies, contains(inverse.operationId));
    expect(replay.operationId, isNot(created.single.operationId));
    expect(repositoryWrites, 0);

    controller.addPage();
    await controller.flushPendingSaves();
    final saved = (await repository.getNotebook(notebook.uid))!;
    expect(saved.pages, hasLength(2));
    expect(saved.pages.first.inkStrokes, hasLength(1));
    expect((await store.pending()).last.kind, OperationKind.pageCreate);
    controller.deleteLastPage();
    await controller.flushPendingSaves();
    expect((await repository.getNotebook(notebook.uid))?.pages, hasLength(1));
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
    await controller.historyReady;
    await controller.preferencesReady;
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

    expect(
      controller.applyConfirmedShareObjectPatch(
        pageId: id,
        objectId: 'text-a',
        text: text('text-a', 'A'),
        sortIndex: 0,
      ),
      isTrue,
    );
    expect(
      controller.applyConfirmedShareObjectPatch(
        pageId: id,
        objectId: 'text-b',
        text: text('text-b', 'B'),
        sortIndex: 1,
      ),
      isTrue,
    );
    expect(
      controller.applyConfirmedShareObjectPatch(
        pageId: id,
        objectId: 'text-a',
        text: text('text-a', 'Changed'),
        sortIndex: 0,
      ),
      isTrue,
    );
    expect(controller.currentPage.textBlocks.map((e) => e.id).toList(), [
      'text-a',
      'text-b',
    ]);

    expect(
      controller.applyConfirmedShareObjectPatch(
        pageId: id,
        objectId: 'image-a',
        image: image('image-a'),
        sortIndex: 0,
      ),
      isTrue,
    );
    expect(
      controller.applyConfirmedShareObjectPatch(
        pageId: id,
        objectId: 'image-b',
        image: image('image-b'),
        sortIndex: 1,
      ),
      isTrue,
    );
    expect(
      controller.applyConfirmedShareObjectPatch(
        pageId: id,
        objectId: 'image-a',
        image: image('image-a'),
        sortIndex: 1,
      ),
      isTrue,
    );
    expect(controller.currentPage.imageBlocks.map((e) => e.id).toList(), [
      'image-b',
      'image-a',
    ]);
  });

  test(
    'failed inverse preserves history and retries without a sequence gap',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final notebook = await repository.createNotebook();
      final store = OperationStore(database);
      final projector = EditorSqliteProjector(database);
      final engine = SyncEngine(
        store: store,
        gateway: _OfflineGateway(),
        actorId: 'inverse-retry',
        checkpointScope: 'inverse-retry',
        enableRealtime: false,
        applyRemote: (operation, _) => projector.apply(operation),
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
      controller.addInkStroke(const [InkPoint(dx: 4, dy: 5, pressure: 0.6)]);
      await controller.flushPendingSaves();
      final created = (await store.pending()).single;
      await database.customStatement('''
      CREATE TEMP TRIGGER reject_inverse BEFORE INSERT ON operations
      WHEN NEW.kind = 'object.delete'
      BEGIN SELECT RAISE(ABORT, 'injected inverse write failure'); END
    ''');
      controller.undo();
      await controller.flushPendingSaves();
      expect(controller.currentPage.inkStrokes.single.id, created.objectId);
      expect(
        (await repository.getNotebook(
          notebook.uid,
        ))!.pages.single.inkStrokes.single.id,
        created.objectId,
      );
      expect((await store.pending()).single.operationId, created.operationId);
      expect(controller.canUndo, isTrue);
      expect(controller.canRedo, isFalse);
      await database.customStatement('DROP TRIGGER reject_inverse');
      controller.undo();
      await controller.flushPendingSaves();
      final inverse = (await store.pending()).last;
      expect(inverse.actorSeq, created.actorSeq + 1);
      expect(inverse.revertsOperationId, created.operationId);
      expect(controller.currentPage.inkStrokes, isEmpty);
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isTrue);
    },
  );

  for (final autosaved in [false, true]) {
    test(
      'typing then deleting preserves both history gestures, saved=$autosaved',
      () async {
        final database = NotesDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final repository = NotebookRepository(database);
        final notebook = await repository.createNotebook();
        final store = OperationStore(database);
        final projector = EditorSqliteProjector(database);
        final engine = SyncEngine(
          store: store,
          gateway: _OfflineGateway(),
          actorId: 'type-delete-test',
          checkpointScope: 'type-delete-test',
          enableRealtime: false,
          applyRemote: (operation, _) => projector.apply(operation),
        );
        addTearDown(engine.stop);
        Completer<void>? typedCommitted;
        final writer = EditorV2OperationWriter(
          syncEngine: engine,
          projector: projector,
          onCommitted: (_, __) {
            final waiter = typedCommitted;
            if (waiter != null && !waiter.isCompleted) {
              waiter.complete();
            }
          },
        );
        final block = TextBlock(
          id: 'type-then-delete',
          text: 'Original',
          deltaJson: jsonEncode([
            {'insert': 'Original\n'},
          ]),
          position: Offset.zero,
          fontSize: 18,
          color: const Color(0xFF123456),
          width: 200,
        );
        await writer.writePageChange(
          documentId: notebook.uid,
          before: notebook.pages.single,
          after: notebook.pages.single.copyWith(textBlocks: [block]),
        );
        final controller = EditorController(
          repository: repository,
          notebook: (await repository.getNotebook(notebook.uid))!,
          operationWriter: writer,
          saveDebounce: const Duration(milliseconds: 10),
        );
        addTearDown(controller.dispose);
        controller.setActiveTextBlock(block.id, null);
        final typedSaved = Completer<void>();
        typedCommitted = typedSaved;
        controller.updateTextBlockContent(
          controller.currentPage.textBlocks.single,
          plainText: 'Latest draft',
          deltaJson: jsonEncode([
            {'insert': 'Latest draft\n'},
          ]),
        );
        if (autosaved) {
          await typedSaved.future.timeout(const Duration(seconds: 5));
        }
        controller.deleteTextBlock(block.id);
        await controller.flushPendingSaves();
        expect(controller.currentPage.textBlocks, isEmpty);
        controller.undo();
        await controller.flushPendingSaves();
        final restoredId = controller.currentPage.textBlocks.single.id;
        expect(restoredId, isNot(block.id));
        expect(controller.currentPage.textBlocks.single.text, 'Latest draft');
        controller.undo();
        await controller.flushPendingSaves();
        expect(controller.currentPage.textBlocks.single.id, restoredId);
        expect(controller.currentPage.textBlocks.single.text, 'Original');
        expect(controller.canUndo, isFalse);
        controller.redo();
        await controller.flushPendingSaves();
        expect(controller.currentPage.textBlocks.single.id, restoredId);
        expect(controller.currentPage.textBlocks.single.text, 'Latest draft');
        controller.redo();
        await controller.flushPendingSaves();
        expect(controller.currentPage.textBlocks, isEmpty);
      },
    );
  }

  for (final restoreOriginal in [false, true]) {
    test(
      'text autosaves share one history gesture, noop=$restoreOriginal',
      () async {
        final database = NotesDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final repository = NotebookRepository(database);
        final notebook = await repository.createNotebook();
        final store = OperationStore(database);
        final projector = EditorSqliteProjector(database);
        final engine = SyncEngine(
          store: store,
          gateway: _OfflineGateway(),
          actorId: 'text-gesture-test',
          checkpointScope: 'text-gesture-test',
          enableRealtime: false,
          applyRemote: (operation, _) => projector.apply(operation),
        );
        addTearDown(engine.stop);
        Completer<void>? committed;
        final writer = EditorV2OperationWriter(
          syncEngine: engine,
          projector: projector,
          onCommitted: (_, __) {
            if (committed != null && !committed!.isCompleted) {
              committed!.complete();
            }
          },
        );
        final original = TextBlock(
          id: 'autosaved-text',
          text: 'Original',
          deltaJson: jsonEncode([
            {'insert': 'Original\n'},
          ]),
          position: Offset.zero,
          fontSize: 18,
          color: const Color(0xFF112233),
          width: 200,
        );
        await writer.writePageChange(
          documentId: notebook.uid,
          before: notebook.pages.single,
          after: notebook.pages.single.copyWith(textBlocks: [original]),
        );
        final controller = EditorController(
          repository: repository,
          notebook: (await repository.getNotebook(notebook.uid))!,
          operationWriter: writer,
          saveDebounce: const Duration(milliseconds: 10),
        );
        addTearDown(controller.dispose);
        controller.setActiveTextBlock(original.id, null);

        Future<void> autoSave(String text) async {
          committed = Completer<void>();
          controller.updateTextBlockContent(
            controller.currentPage.textBlocks.single,
            plainText: text,
            deltaJson: jsonEncode([
              {'insert': '$text\n'},
            ]),
          );
          await committed!.future.timeout(const Duration(seconds: 5));
          expect(
            (await repository.getNotebook(
              notebook.uid,
            ))!.pages.single.textBlocks.single.text,
            text,
          );
        }

        await autoSave('First autosave');
        await autoSave(restoreOriginal ? 'Original' : 'Second autosave');
        // End the edit after its latest content is already durable.
        controller.setActiveTextBlock(null, null);
        await controller.flushPendingSaves();
        expect(controller.canUndo, !restoreOriginal);
        if (restoreOriginal) {
          expect(
            (await repository.getNotebook(
              notebook.uid,
            ))!.pages.single.textBlocks.single.deltaJson,
            original.deltaJson,
          );
          return;
        }
        final originalOperations = await store.pending();
        final gestureEnd = originalOperations.last.operationId;
        controller.undo();
        await controller.flushPendingSaves();
        final afterUndo = await store.pending();
        final inverse = afterUndo.skip(originalOperations.length).toList();
        expect(inverse, isNotEmpty);
        for (final operation in inverse) {
          expect(operation.revertsOperationId, gestureEnd);
          expect(operation.dependencies, contains(gestureEnd));
        }
        expect(
          (await repository.getNotebook(
            notebook.uid,
          ))!.pages.single.textBlocks.single.text,
          'Original',
        );
        expect(controller.canUndo, isFalse);
        expect(controller.canRedo, isTrue);
        controller.redo();
        await controller.flushPendingSaves();
        final afterRedo = await store.pending();
        final replay = afterRedo.skip(afterUndo.length).toList();
        expect(replay, isNotEmpty);
        for (final operation in replay) {
          expect(operation.revertsOperationId, inverse.last.operationId);
          expect(operation.dependencies, contains(inverse.last.operationId));
          expect(
            originalOperations.map((item) => item.operationId),
            isNot(contains(operation.operationId)),
          );
        }
        expect(
          (await repository.getNotebook(
            notebook.uid,
          ))!.pages.single.textBlocks.single.text,
          'Second autosave',
        );
        controller.undo();
        await controller.flushPendingSaves();
        final repeatedInverse = (await store.pending()).skip(afterRedo.length);
        expect(repeatedInverse, isNotEmpty);
        expect(
          repeatedInverse.map((item) => item.revertsOperationId),
          everyElement(replay.last.operationId),
        );
        expect(controller.currentPage.textBlocks.single.text, 'Original');
      },
    );
  }

  test(
    'opt-in controller rejects a projection from a different SQLite',
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
    },
  );
  test('rapid independent strokes have separate v2 Undo boundaries', () async {
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
    editor.undo();
    await editor.flushPendingSaves();
    editor.undo();
    await editor.flushPendingSaves();
    expect(editor.currentPage.inkStrokes, isEmpty);
    final beforeFailedRestore = (await store.pending()).length;
    await db.customStatement('''
      CREATE TEMP TRIGGER reject_restore BEFORE INSERT ON operations
      WHEN NEW.kind = 'stroke.create'
      BEGIN SELECT RAISE(ABORT, 'injected restoration failure'); END
    ''');
    editor.redo();
    await editor.flushPendingSaves();
    expect(editor.currentPage.inkStrokes, isEmpty);
    expect(editor.canRedo, isTrue);
    expect(await store.pending(), hasLength(beforeFailedRestore));
    await db.customStatement('DROP TRIGGER reject_restore');
    editor.redo();
    await editor.flushPendingSaves();
    final firstRestoredId = editor.currentPage.inkStrokes.single.id;
    final beforeSecondRedo = (await store.pending()).length;
    editor.redo();
    await editor.flushPendingSaves();
    expect(editor.currentPage.inkStrokes.first.id, firstRestoredId);
    expect(
      (await store.pending()).skip(beforeSecondRedo).map((op) => op.kind),
      [OperationKind.strokeCreate],
    );
    editor.undo();
    await editor.flushPendingSaves();
    expect(editor.currentPage.inkStrokes.single.id, firstRestoredId);

    editor.addPage();
    await editor.flushPendingSaves();
    final originalPageId = editor.currentPage.id;
    editor.addInkStroke(const [InkPoint(dx: 8, dy: 9, pressure: 0.7)]);
    await editor.flushPendingSaves();
    editor.undo();
    await editor.flushPendingSaves();
    editor.undo();
    await editor.flushPendingSaves();
    expect(editor.pages, hasLength(1));
    editor.redo();
    await editor.flushPendingSaves();
    final restoredPageId = editor.pages.last.id;
    expect(restoredPageId, isNot(originalPageId));
    final beforeInkRedo = (await store.pending()).length;
    editor.redo();
    await editor.flushPendingSaves();
    expect(editor.pages, hasLength(2));
    expect(editor.pages.last.id, restoredPageId);
    expect(editor.pages.last.inkStrokes, hasLength(1));
    expect((await store.pending()).skip(beforeInkRedo).map((op) => op.kind), [
      OperationKind.strokeCreate,
    ]);
  });
}
