import 'dart:io';
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
import 'package:program/features/editor/state/editor_operation_bridge.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/text_block.dart';

import 'support/native_test_documents.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('Offline recovery test.');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('Offline recovery test.');
}

void main() {
  useIsolatedNativeTestDocuments();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v2 journal, verified inline asset and outbox survive reopen', () async {
    final directory = await Directory.systemTemp.createTemp('nn-v2-crash-');
    addTearDown(() => directory.delete(recursive: true));
    final dbFile = File('${directory.path}/notes.sqlite');

    final database = NotesDatabase(NativeDatabase(dbFile));
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
      actorId: 'disk-recovery-peer',
      checkpointScope: 'disk-recovery',
      enableRealtime: false,
      applyRemote: (op, _) => projector.apply(op),
    );
    final writer = EditorV2OperationWriter(
      syncEngine: engine,
      projector: projector,
    );

    final bytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
    final verified = VerifiedEditorAsset(
      assetId: 'recovery-inline-image',
      sha256: crypto.sha256.convert(bytes).toString(),
      sizeBytes: bytes.length,
      mediaType: 'image/png',
    );
    buffer.stage(receipt: verified.attachPayload, bytes: bytes);
    final page = notebook.pages.single;
    final updated = page.copyWith(
      inkStrokes: [
        InkStroke(
          id: 'ink-recovery',
          color: const Color(0xFF123456),
          width: 2,
          tool: DrawingTool.pen,
          points: [const InkPoint(dx: 3, dy: 4, pressure: 0.5)],
        ),
      ],
      textBlocks: [
        TextBlock(
          id: 'inline-recovery',
          text: '\uFFFC',
          deltaJson: r'[{"insert":{"image":"asset:recovery-inline-image"}}]',
          position: Offset.zero,
          fontSize: 18,
          color: const Color(0xFF123456),
          width: 200,
        ),
      ],
    );
    final committed = await writer.writePageChange(
      documentId: notebook.uid,
      before: page,
      after: updated,
      verifiedAssets: {verified.assetId: verified},
    );
    expect(committed.map((op) => op.kind), [
      OperationKind.strokeCreate,
      OperationKind.objectCreate,
      OperationKind.assetAttach,
      OperationKind.textInsert,
    ]);
    final identities = committed.map((op) => op.operationId).toList();
    await engine.stop();
    await database.close();

    final reopened = NotesDatabase(NativeDatabase(dbFile));
    addTearDown(reopened.close);
    final recovered = NotebookRepository(reopened);
    final recoveredStore = OperationStore(reopened);
    final loaded = (await recovered.getNotebook(notebook.uid))!;
    expect(loaded.pages.single.inkStrokes.single.id, 'ink-recovery');
    expect(
      loaded.pages.single.textBlocks.single.deltaJson,
      contains('asset:recovery-inline-image'),
    );
    expect(
      (await recoveredStore.pending())
          .map((operation) => operation.operationId)
          .toList(),
      identities,
    );
    final recoveredProjector = EditorSqliteProjector(reopened);
    expect(
      await recoveredProjector.verifiedTextAssetBytes(
        documentId: notebook.uid,
        pageId: page.id,
        objectId: 'inline-recovery',
        assetId: verified.assetId,
      ),
      orderedEquals(bytes),
    );
    await expectLater(recovered.saveNotebook(loaded), throwsStateError);
  });

  for (final kind in [NotebookKind.notebook, NotebookKind.board]) {
    test('v2 $kind never saves an unfinished shape drag', () async {
      final directory = await Directory.systemTemp.createTemp('nn-v2-shape-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/notes.sqlite');

      EditorV2OperationWriter writerFor(NotesDatabase database) {
        final projector = EditorSqliteProjector(database);
        return EditorV2OperationWriter(
          syncEngine: SyncEngine(
            store: OperationStore(database),
            gateway: _OfflineGateway(),
            actorId: 'offline-shape-editor',
            checkpointScope: 'shape-recovery',
            enableRealtime: false,
            applyRemote: (op, _) => projector.apply(op),
          ),
          projector: projector,
        );
      }

      final database = NotesDatabase(NativeDatabase(file));
      final repository = NotebookRepository(database);
      final writer = writerFor(database);
      final store = OperationStore(database);
      late final String documentId;
      late final String shapeId;
      late final String otherId;
      late final List<String> durableOperations;
      const originalEnd = Offset(100, 0);
      const committedEnd = Offset(140, 30);
      try {
        await repository.enableAccountOperations(writer);
        final notebook = kind == NotebookKind.board
            ? await repository.createBoard()
            : await repository.createNotebook();
        documentId = notebook.uid;
        final editor = EditorController(
          repository: repository,
          notebook: notebook,
          operationWriter: writer,
          saveDebounce: const Duration(days: 1),
        );
        try {
          await editor.preferencesReady;
          shapeId = editor.addInkStroke(const [
            InkPoint(dx: 0, dy: 0, pressure: 1),
            InkPoint(dx: 100, dy: 0, pressure: 1),
          ], toolOverride: DrawingTool.line)!;
          await editor.flushPendingSaves();
          final before = editor.shapeStrokeOnPage(0, shapeId)!;

          // Flush an earlier, valid gesture while a shape preview is visible.
          otherId = editor.addInkStroke(const [
            InkPoint(dx: 3, dy: 4, pressure: 0.5),
          ], toolOverride: DrawingTool.pen)!;
          editor.startShapeEdit(0, shapeId);
          editor.beginObjectTransform();
          editor.previewShapeStrokeOnPage(
            0,
            before.copyWith(
              points: const [
                InkPoint(dx: 0, dy: 0, pressure: 1),
                InkPoint(dx: 150, dy: 80, pressure: 1),
              ],
            ),
          );
          expect(
            editor.shapeStrokeOnPage(0, shapeId)!.points.last.toOffset(),
            const Offset(150, 80),
          );
          await editor.flushPendingSaves();
          final duringDrag = (await repository.getNotebook(documentId))!;
          expect(duringDrag.pages.single.inkStrokes.map((s) => s.id), [
            shapeId,
            otherId,
          ]);
          expect(
            duringDrag.pages.single.inkStrokes.first.points.last.toOffset(),
            originalEnd,
          );
          expect(
            (await store.pending()).where(
              (op) => op.kind == OperationKind.objectTransform,
            ),
            isEmpty,
          );

          // Leaving the shape tool cancels the preview without a write.
          editor.finishShapeEdit();
          editor.endObjectTransform();
          expect(
            editor.shapeStrokeOnPage(0, shapeId)!.points.last.toOffset(),
            originalEnd,
          );
          await editor.flushPendingSaves();
          expect(
            (await store.pending()).where(
              (op) => op.kind == OperationKind.objectTransform,
            ),
            isEmpty,
          );

          editor.startShapeEdit(0, shapeId);
          editor.beginObjectTransform();
          final after = before.copyWith(
            points: const [
              InkPoint(dx: 0, dy: 0, pressure: 1),
              InkPoint(dx: 140, dy: 30, pressure: 1),
            ],
          );
          editor.previewShapeStrokeOnPage(0, after);
          final beforeFailure = await store.pending();
          await database.customStatement('''
            CREATE TEMP TRIGGER reject_shape_transform
            BEFORE INSERT ON operations WHEN NEW.kind = 'object.transform'
            BEGIN SELECT RAISE(ABORT, 'injected shape commit failure'); END
          ''');
          editor.commitShapeStrokeOnPage(0, before, after);
          editor.endObjectTransform();
          try {
            await expectLater(
              editor.flushPendingSaves(),
              throwsA(isA<DataIntegrityProtectionException>()),
            );
            final rolledBack = (await repository.getNotebook(documentId))!;
            expect(
              rolledBack.pages.single.inkStrokes.first.points.last.toOffset(),
              originalEnd,
            );
            expect(
              (await store.pending()).map((op) => op.operationId),
              beforeFailure.map((op) => op.operationId),
            );
          } finally {
            await database.customStatement(
              'DROP TRIGGER reject_shape_transform',
            );
          }
          await editor.flushPendingSaves();
          final pending = await store.pending();
          final transform = pending.singleWhere(
            (op) => op.kind == OperationKind.objectTransform,
          );
          expect(transform.objectId, shapeId);
          expect(transform.actorSeq, beforeFailure.last.actorSeq + 1);
          durableOperations = pending.map((op) => op.operationId).toList();
        } finally {
          editor.dispose();
        }
      } finally {
        await writer.syncEngine.stop();
        await database.close();
      }

      final reopened = NotesDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      final recovered = NotebookRepository(reopened);
      final loaded = (await recovered.getNotebook(documentId))!;
      final recoveredStore = OperationStore(reopened);
      expect(
        loaded.pages.single.inkStrokes.first.points.last.toOffset(),
        committedEnd,
      );
      expect(
        (await recoveredStore.pending()).map((op) => op.operationId),
        durableOperations,
      );
      final resumedWriter = writerFor(reopened);
      addTearDown(resumedWriter.syncEngine.stop);
      final resumed = EditorController(
        repository: recovered,
        notebook: loaded,
        operationWriter: resumedWriter,
      );
      addTearDown(resumed.dispose);
      await resumed.historyReady;
      expect(resumed.canUndo, isTrue);
      resumed.undo();
      await resumed.flushPendingSaves();
      expect(resumed.currentPage.inkStrokes.map((stroke) => stroke.id), [
        shapeId,
        otherId,
      ]);
      expect(
        resumed.currentPage.inkStrokes.first.points.last.toOffset(),
        originalEnd,
      );
    });
  }
}
