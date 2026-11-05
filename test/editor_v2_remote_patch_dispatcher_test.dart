import 'dart:typed_data';

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

  test('image create does not repaint before verified remote attach',
      () async {
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

  test('remote patches modify one page and preserve object identity',
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
      payload: const {
        'toPageId': 'losing-destination',
        'sortIndex': 0,
      },
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
    await expectLater(
      dispatcher.onRemoteCommitted(deleted),
      throwsStateError,
    );
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
    expect(await store.checkpoint('remote-patch-test'), 6);
    expect(await store.pending(), isEmpty);
  });
}
