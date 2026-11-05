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
import 'package:program/features/editor/state/editor_operation_bridge.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/text_block.dart';

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
}
