import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/data/sync/verified_editor_asset_buffer.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/editor/state/editor_v2_remote_patch_dispatcher.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:uuid/uuid.dart';

import 'support/native_test_documents.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('No network.');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('No network.');
}

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'deferred remote patch blocks history until successful delivery',
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
        actorId: 'deferred-history',
        checkpointScope: 'deferred-history',
        enableRealtime: false,
        applyRemote: (operation, _) => projector.apply(operation),
      );
      addTearDown(engine.stop);
      final editor = EditorController(
        repository: repository,
        notebook: notebook,
        operationWriter: EditorV2OperationWriter(
          syncEngine: engine,
          projector: projector,
        ),
        saveDebounce: const Duration(days: 1),
      );
      addTearDown(editor.dispose);
      await editor.historyReady;
      await editor.preferencesReady;
      final dispatcher = EditorV2RemotePatchDispatcher(
        editor: editor,
        repository: repository,
      );
      for (var i = 0; i < 2; i++) {
        editor.addInkStroke([InkPoint(dx: 1.0 + i, dy: 2, pressure: 0.5)]);
        await editor.flushPendingSaves();
      }
      editor.undo();
      await editor.flushPendingSaves();
      expect(editor.canUndo, isTrue);
      expect(editor.canRedo, isTrue);
      final pending = await store.pending();
      final remote = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'remote-deferred-history',
        actorSeq: 1,
        logicalClock: pending.last.logicalClock + 1,
        dependencies: [pending.last.operationId],
        documentId: notebook.uid,
        pageId: notebook.pages.single.id,
        objectId: 'remote-deferred-stroke',
        kind: OperationKind.strokeCreate,
        payload: const {
          'value': {
            'objectType': 'stroke',
            'colorValue': 0xFF123456,
            'width': 2.0,
            'toolIndex': 0,
            'sortIndex': 1,
            'points': [
              [4.0, 6.0, 0.5],
            ],
          },
        },
      );
      await store.applyRemote(
        remote,
        serverSequence: 100,
        apply: () => projector.apply(remote),
      );
      editor.activeTextBlockId = 'active-text-edit';
      await expectLater(dispatcher.onRemoteCommitted(remote), throwsStateError);
      expect(editor.canUndo, isFalse);
      expect(editor.canRedo, isFalse);
      editor.undo();
      editor.redo();
      await editor.flushPendingSaves();
      expect(
        (await store.pending()).map((op) => op.operationId),
        pending.map((op) => op.operationId),
      );
      editor.activeTextBlockId = null;
      await dispatcher.onRemoteCommitted(remote);
      expect(editor.currentPage.inkStrokes, hasLength(2));
      expect(
        editor.currentPage.inkStrokes.map((s) => s.id),
        contains(remote.objectId),
      );
      editor.viewPan = const Offset(10, 20);
      editor.addInkStroke(const [InkPoint(dx: 8, dy: 9, pressure: 0.5)]);
      await editor.flushPendingSaves();
      expect(editor.canUndo, isTrue);
      editor.undo();
      await editor.flushPendingSaves();
      expect(editor.currentPage.inkStrokes, hasLength(2));
      expect(
        editor.currentPage.inkStrokes.map((s) => s.id),
        contains(remote.objectId),
      );
      expect(editor.viewPan, const Offset(10, 20));
    },
  );

  test('image create does not repaint before verified remote attach', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final store = OperationStore(database);
    final buffer = VerifiedEditorAssetBuffer();
    final projector = EditorSqliteProjector(
      database,
      verifiedAssetBuffer: buffer,
    );
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'local',
      checkpointScope: 'image-patch-test',
      enableRealtime: false,
      applyRemote: (operation, _) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final editor = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      ),
    );
    addTearDown(editor.dispose);
    final dispatcher = EditorV2RemotePatchDispatcher(
      editor: editor,
      repository: repository,
    );
    var repaints = 0;
    editor.addListener(() => repaints++);
    final bytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
    final receipt = <String, dynamic>{
      'assetId': 'remote-verified',
      'sha256': crypto.sha256.convert(bytes).toString(),
      'sizeBytes': bytes.length,
      'mediaType': 'image/png',
    };
    final created = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'remote-image-peer',
      actorSeq: 1,
      logicalClock: 1,
      dependencies: const [],
      documentId: notebook.uid,
      pageId: notebook.pages.first.id,
      objectId: 'remote-image-object',
      kind: OperationKind.objectCreate,
      payload: const {
        'value': {
          'objectType': 'image',
          'assetId': 'remote-verified',
          'dx': 5.0,
          'dy': 6.0,
          'width': 110.0,
          'height': 90.0,
          'rotation': 0.0,
          'cropLeft': 0.0,
          'cropTop': 0.0,
          'cropRight': 1.0,
          'cropBottom': 1.0,
          'sortIndex': 0,
        },
      },
    );
    await store.applyRemote(
      created,
      serverSequence: 1,
      apply: () => projector.apply(created),
    );
    await dispatcher.onRemoteCommitted(created);
    expect(repaints, 0);
    expect(editor.pages.single.imageBlocks, isEmpty);

    final attached = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'remote-image-peer',
      actorSeq: 2,
      logicalClock: 2,
      documentId: notebook.uid,
      pageId: notebook.pages.first.id,
      objectId: 'remote-image-object',
      kind: OperationKind.assetAttach,
      payload: receipt,
      dependencies: [created.operationId],
    );
    buffer.stage(receipt: receipt, bytes: bytes);
    await store.applyRemote(
      attached,
      serverSequence: 2,
      apply: () => projector.apply(attached),
    );
    await dispatcher.onRemoteCommitted(attached);
    expect(repaints, 1);
    expect(editor.pages.single.imageBlocks.single.bytes, orderedEquals(bytes));
    expect(editor.pages.single.imageBlocks.single.id, 'remote-image-object');
  });

  test('remote patches modify one page and preserve object identity', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'local',
      checkpointScope: 'remote-patch-test',
      enableRealtime: false,
      applyRemote: (operation, pending) => projector.apply(operation),
    );
    addTearDown(engine.stop);
    final editor = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      ),
    );
    addTearDown(editor.dispose);
    final dispatcher = EditorV2RemotePatchDispatcher(
      editor: editor,
      repository: repository,
    );
    var clock = 0;
    String? previous;

    Future<OperationEnvelope> remote({
      required OperationKind kind,
      required String objectId,
      required Map<String, dynamic> payload,
      String? pageId,
    }) async {
      clock++;
      final current = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'other-device',
        actorSeq: clock,
        logicalClock: clock,
        documentId: notebook.uid,
        pageId: pageId,
        objectId: objectId,
        kind: kind,
        payload: payload,
        dependencies: previous == null ? [] : [previous!],
      );
      await store.applyRemote(
        current,
        serverSequence: clock,
        checkpointScope: 'remote-patch-test',
        apply: () => projector.apply(current),
      );
      previous = current.operationId;
      return current;
    }

    final created = await remote(
      kind: OperationKind.strokeCreate,
      pageId: notebook.pages.first.id,
      objectId: 'remote-ink',
      payload: const {
        'value': {
          'objectType': 'stroke',
          'colorValue': 0xFF223344,
          'width': 2.0,
          'toolIndex': 0,
          'sortIndex': 0,
          'points': [
            [4.0, 6.0, 0.5],
          ],
        },
      },
    );
    await dispatcher.onRemoteCommitted(created);
    expect(editor.currentPage.id, notebook.pages.first.id);
    expect(editor.currentPage.inkStrokes.single.id, 'remote-ink');
    await dispatcher.onRemoteCommitted(created);
    expect(editor.currentPage.inkStrokes, hasLength(1));

    final pageCreated = await remote(
      kind: OperationKind.pageCreate,
      objectId: 'remote-page',
      payload: const {
        'value': {'title': 'Remote', 'isBookmarked': false},
      },
    );
    await dispatcher.onRemoteCommitted(pageCreated);
    expect(editor.pages, hasLength(2));
    expect(editor.currentPage.id, notebook.pages.first.id);

    final moved = await remote(
      kind: OperationKind.objectMove,
      pageId: notebook.pages.first.id,
      objectId: 'remote-ink',
      payload: const {'toPageId': 'remote-page', 'sortIndex': 0},
    );
    var moveRepaints = 0;
    void onMove() {
      moveRepaints++;
      // A single UI revision must contain both sides of the move.
      expect(editor.pages.first.inkStrokes, isEmpty);
      expect(editor.pages.last.inkStrokes.single.id, 'remote-ink');
    }

    editor.addListener(onMove);
    await dispatcher.onRemoteCommitted(moved);
    editor.removeListener(onMove);
    expect(moveRepaints, 1);
    expect(editor.pages.first.inkStrokes, isEmpty);
    expect(editor.pages.last.inkStrokes.single.id, 'remote-ink');

    final ignoredPage = await remote(
      kind: OperationKind.pageCreate,
      objectId: 'losing-destination',
      payload: const {
        'value': {'title': 'Loser', 'isBookmarked': false},
      },
    );
    await dispatcher.onRemoteCommitted(ignoredPage);
    final ignoredMove = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'concurrent-loser',
      actorSeq: 1,
      logicalClock: 2,
      documentId: notebook.uid,
      pageId: notebook.pages.first.id,
      objectId: 'remote-ink',
      kind: OperationKind.objectMove,
      payload: const {'toPageId': 'losing-destination', 'sortIndex': 0},
      dependencies: [created.operationId],
    );
    expect(
      await store.applyRemote(
        ignoredMove,
        serverSequence: 5,
        apply: () => projector.apply(ignoredMove),
      ),
      isTrue,
    );
    // The new actor's older move was committed as a deterministic no-op.
    // UI delivery must use the winner's durable location and not block.
    await dispatcher.onRemoteCommitted(ignoredMove);
    expect(editor.pages[1].inkStrokes.single.id, 'remote-ink');
    expect(editor.pages[2].inkStrokes, isEmpty);

    final deleted = await remote(
      kind: OperationKind.objectDelete,
      pageId: 'remote-page',
      objectId: 'remote-ink',
      payload: const {},
    );
    editor.activeTextBlockId = 'active-editor-text';
    await expectLater(dispatcher.onRemoteCommitted(deleted), throwsStateError);
    expect(editor.pages[1].inkStrokes.single.id, 'remote-ink');
    editor.activeTextBlockId = null;
    await dispatcher.onRemoteCommitted(deleted);
    expect(editor.pages[1].inkStrokes, isEmpty);

    final pageDeleted = await remote(
      kind: OperationKind.pageDelete,
      objectId: 'remote-page',
      payload: const {},
    );
    await dispatcher.onRemoteCommitted(pageDeleted);
    expect(editor.pages, hasLength(2));
    expect(editor.currentPage.id, notebook.pages.first.id);

    // A lower-ranked move can arrive after the object and its last page
    // have been deleted. SQLite records its actor sequence as a no-op.
    // The UI delivery must also succeed without resurrecting the object.
    final lateMove = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'late-concurrent-move',
      actorSeq: 1,
      logicalClock: 2,
      documentId: notebook.uid,
      pageId: notebook.pages.first.id,
      objectId: 'remote-ink',
      kind: OperationKind.objectMove,
      payload: const {'toPageId': 'losing-destination', 'sortIndex': 0},
      dependencies: [created.operationId],
    );
    expect(
      await store.applyRemote(
        lateMove,
        serverSequence: 7,
        apply: () => projector.apply(lateMove),
      ),
      isTrue,
    );
    await dispatcher.onRemoteCommitted(lateMove);
    expect(editor.pages.expand((page) => page.inkStrokes), isEmpty);

    // A missing target without a durable tombstone is still corruption,
    // not a reason to discard a remote move notification.
    final unverifiedMissing = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'missing-without-delete',
      actorSeq: 1,
      logicalClock: 2,
      documentId: notebook.uid,
      pageId: notebook.pages.first.id,
      objectId: 'not-a-deleted-object',
      kind: OperationKind.objectMove,
      payload: const {'toPageId': 'losing-destination', 'sortIndex': 0},
      dependencies: [created.operationId],
    );
    await expectLater(
      dispatcher.onRemoteCommitted(unverifiedMissing),
      throwsStateError,
    );
    expect(await store.checkpoint('remote-patch-test'), 6);
    expect(await store.pending(), isEmpty);
  });
  test('remote document set/delete cannot block v2 UI delivery', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'local',
      checkpointScope: 'document-metadata-test',
      enableRealtime: false,
      applyRemote: (op, _) => projector.apply(op),
    );
    addTearDown(engine.stop);
    final editor = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      ),
    );
    addTearDown(editor.dispose);
    final notifications = <OperationKind>[];
    final dispatcher = EditorV2RemotePatchDispatcher(
      editor: editor,
      repository: repository,
      onDocumentCommitted: (op) async {
        notifications.add(op.kind);
      },
    );
    OperationEnvelope remote(
      OperationKind kind,
      int seq,
      Map<String, dynamic> payload, {
      List<String> dependencies = const [],
    }) => OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'remote-doc',
      actorSeq: seq,
      logicalClock: seq,
      documentId: notebook.uid,
      kind: kind,
      payload: payload,
      dependencies: dependencies,
    );
    final rename = remote(OperationKind.documentSet, 1, const {
      'properties': {'title': 'Renamed', 'folder': 'Other'},
    });
    await store.applyRemote(
      rename,
      serverSequence: 1,
      apply: () => projector.apply(rename),
    );
    await dispatcher.onRemoteCommitted(rename);
    expect(editor.notebook.title, 'Renamed');
    expect(editor.notebook.folder, 'Other');
    expect(editor.pages.single.id, notebook.pages.single.id);

    final deletion = remote(
      OperationKind.documentDelete,
      2,
      const {},
      dependencies: [rename.operationId],
    );
    await store.applyRemote(
      deletion,
      serverSequence: 2,
      apply: () => projector.apply(deletion),
    );
    await dispatcher.onRemoteCommitted(deletion);
    expect(editor.isV2DocumentDeleted, isTrue);
    expect(editor.canApplyConfirmedRemoteNotebook, isFalse);
    expect(await repository.getNotebook(notebook.uid), isNull);
    await dispatcher.onRemoteCommitted(deletion);
    final another = await repository.createNotebook();
    final changedOtherDocument = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'remote-other-doc',
      actorSeq: 1,
      logicalClock: 3,
      dependencies: const [],
      documentId: another.uid,
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'Another document'},
      },
    );
    await store.applyRemote(
      changedOtherDocument,
      serverSequence: 3,
      apply: () => projector.apply(changedOtherDocument),
    );
    await dispatcher.onRemoteCommitted(changedOtherDocument);
    expect(editor.isV2DocumentDeleted, isTrue);
    expect(notifications, [
      OperationKind.documentSet,
      OperationKind.documentDelete,
      OperationKind.documentDelete,
      OperationKind.documentSet,
    ]);
  });

  for (final objectType in ['stroke', 'text', 'image']) {
    for (final winnerFirst in [false, true]) {
      test('concurrent $objectType moves keep one UI owner '
          '(winner first: $winnerFirst)', () async {
        final database = NotesDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final repository = NotebookRepository(database);
        final notebook = await repository.createNotebook();
        final store = OperationStore(database);
        final buffer = VerifiedEditorAssetBuffer();
        final projector = EditorSqliteProjector(
          database,
          verifiedAssetBuffer: buffer,
        );
        final engine = SyncEngine(
          store: store,
          gateway: _OfflineGateway(),
          actorId: 'local-move-observer',
          checkpointScope: 'concurrent-moves',
          enableRealtime: false,
          applyRemote: (operation, _) => projector.apply(operation),
        );
        addTearDown(engine.stop);
        final editor = EditorController(
          repository: repository,
          notebook: notebook,
          operationWriter: EditorV2OperationWriter(
            syncEngine: engine,
            projector: projector,
          ),
        );
        addTearDown(editor.dispose);
        await editor.historyReady;
        await editor.preferencesReady;
        final dispatcher = EditorV2RemotePatchDispatcher(
          editor: editor,
          repository: repository,
        );
        var sequence = 0;
        var serverSequence = 0;
        String? previous;
        Future<OperationEnvelope> setup(
          OperationKind kind,
          String objectId,
          Map<String, dynamic> payload, {
          String? pageId,
        }) async {
          sequence++;
          final operation = OperationEnvelope(
            operationId: const Uuid().v4(),
            actorId: 'move-setup',
            actorSeq: sequence,
            logicalClock: sequence,
            documentId: notebook.uid,
            objectId: objectId,
            pageId: pageId,
            kind: kind,
            payload: payload,
            dependencies: previous == null ? [] : [previous!],
          );
          await store.applyRemote(
            operation,
            serverSequence: ++serverSequence,
            apply: () => projector.apply(operation),
          );
          await dispatcher.onRemoteCommitted(operation);
          previous = operation.operationId;
          return operation;
        }

        for (final pageId in ['losing-page', 'winning-page']) {
          await setup(OperationKind.pageCreate, pageId, {
            'value': {'title': pageId, 'isBookmarked': false},
          });
        }
        final sourceId = notebook.pages.single.id;
        const objectId = 'concurrent-object';
        final value = <String, dynamic>{
          'objectType': objectType,
          'sortIndex': 0,
          if (objectType == 'stroke') ...{
            'colorValue': 0xFF223344,
            'width': 2.0,
            'toolIndex': 0,
            'points': [
              [4.0, 6.0, 0.5],
            ],
          } else ...{
            'dx': 5.0,
            'dy': 6.0,
            'width': 110.0,
            'rotation': 0.0,
            if (objectType == 'text') ...{
              'fontSize': 18.0,
              'colorValue': 0xFF223344,
            } else ...{
              'assetId': 'move-image-asset',
              'height': 90.0,
              'cropLeft': 0.0,
              'cropTop': 0.0,
              'cropRight': 1.0,
              'cropBottom': 1.0,
            },
          },
        };
        await setup(
          objectType == 'stroke'
              ? OperationKind.strokeCreate
              : OperationKind.objectCreate,
          objectId,
          {'value': value},
          pageId: sourceId,
        );
        final imageBytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
        if (objectType != 'stroke') {
          final receipt = <String, dynamic>{
            'assetId': 'move-image-asset',
            'sha256': crypto.sha256.convert(imageBytes).toString(),
            'sizeBytes': imageBytes.length,
            'mediaType': 'image/png',
          };
          buffer.stage(receipt: receipt, bytes: imageBytes);
          await setup(
            OperationKind.assetAttach,
            objectId,
            receipt,
            pageId: sourceId,
          );
        }
        if (objectType == 'text') {
          await setup(OperationKind.textInsert, objectId, {
            'afterAtomId': null,
            'atoms': [
              {
                'id': const Uuid().v4(),
                'text': 'T',
                'attributes': {'bold': true},
              },
              {
                'id': const Uuid().v4(),
                'text': '\uFFFC',
                'embed': {'image': 'asset:move-image-asset'},
              },
              {'id': const Uuid().v4(), 'text': '\n'},
            ],
          }, pageId: sourceId);
        }
        final originalText = objectType == 'text'
            ? editor.pages.first.textBlocks.single.deltaJson
            : null;
        editor.setCurrentPage(1);
        editor.viewScale = 1.6;
        editor.viewPan = const Offset(12, 34);

        List<String> owners(Iterable<NotePage> pages) => [
          for (final page in pages)
            if ([
              ...page.inkStrokes.map((item) => item.id),
              ...page.textBlocks.map((item) => item.id),
              ...page.imageBlocks.map((item) => item.id),
            ].contains(objectId))
              page.id,
        ];
        OperationEnvelope move(bool winning) => OperationEnvelope(
          operationId: const Uuid().v4(),
          actorId: winning ? 'move-winner' : 'move-loser',
          actorSeq: 1,
          logicalClock: winning ? 200 : 100,
          documentId: notebook.uid,
          pageId: sourceId,
          objectId: objectId,
          kind: OperationKind.objectMove,
          payload: {
            'toPageId': winning ? 'winning-page' : 'losing-page',
            'sortIndex': 0,
          },
          dependencies: [previous!],
        );
        final moves = [move(winnerFirst), move(!winnerFirst)];
        for (var i = 0; i < moves.length; i++) {
          final operation = moves[i];
          final beforeOwners = owners(editor.pages);
          await store.applyRemote(
            operation,
            serverSequence: ++serverSequence,
            apply: () => projector.apply(operation),
          );
          if (i == 1) {
            editor.activeTextBlockId = 'busy-edit';
            await expectLater(
              dispatcher.onRemoteCommitted(operation),
              throwsStateError,
            );
            expect(owners(editor.pages), beforeOwners);
            editor.activeTextBlockId = null;
          }
          var repaints = 0;
          void onPaint() {
            repaints++;
            expect(owners(editor.pages), hasLength(1));
          }

          editor.addListener(onPaint);
          try {
            await dispatcher.onRemoteCommitted(operation);
          } finally {
            editor.removeListener(onPaint);
          }
          expect(repaints, 1);
          final saved = (await repository.getNotebook(notebook.uid))!;
          expect(owners(editor.pages), owners(saved.pages));
        }
        await dispatcher.onRemoteCommitted(moves.last);
        expect(owners(editor.pages), ['winning-page']);
        expect(editor.currentPage.id, 'losing-page');
        expect(editor.viewScale, 1.6);
        expect(editor.viewPan, const Offset(12, 34));
        expect(await store.pending(), isEmpty);
        final target = editor.pages.last;
        if (objectType == 'image') {
          expect(target.imageBlocks.single.bytes, orderedEquals(imageBytes));
          expect(
            await projector.verifiedUploadBytes({
              'assetId': 'move-image-asset',
              'sha256': crypto.sha256.convert(imageBytes).toString(),
              'sizeBytes': imageBytes.length,
              'mediaType': 'image/png',
            }),
            orderedEquals(imageBytes),
          );
        } else if (objectType == 'text') {
          expect(target.textBlocks.single.deltaJson, originalText);
          expect(
            await projector.verifiedTextAssetBytes(
              documentId: notebook.uid,
              pageId: 'winning-page',
              objectId: objectId,
              assetId: 'move-image-asset',
            ),
            orderedEquals(imageBytes),
          );
        }
      });
    }
  }
}
