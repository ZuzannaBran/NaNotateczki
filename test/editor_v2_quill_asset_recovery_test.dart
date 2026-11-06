import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Variable;
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
import 'package:program/features/notebook/domain/text_block.dart';

import 'support/native_test_documents.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw const SocketException('No transport during local recovery.');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw const SocketException('No transport during local recovery.');
}

class _Session {
  _Session(File file) {
    database = NotesDatabase(NativeDatabase(file));
    repository = NotebookRepository(database);
    store = OperationStore(database);
    projector = EditorSqliteProjector(database, verifiedAssetBuffer: buffer);
    engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'quill-recovery',
      checkpointScope: 'quill-recovery',
      enableRealtime: false,
      applyRemote: (operation, _) => projector.apply(operation),
    );
    writer = EditorV2OperationWriter(syncEngine: engine, projector: projector);
  }

  final buffer = VerifiedEditorAssetBuffer();
  late final NotesDatabase database;
  late final NotebookRepository repository;
  late final OperationStore store;
  late final EditorSqliteProjector projector;
  late final SyncEngine engine;
  late final EditorV2OperationWriter writer;

  Future<void> close() async {
    await engine.stop();
    await database.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();

  for (final type in ['image', 'pdf']) {
    for (final target in ['embed', 'block', 'page']) {
      test('offline $type Undo restores deleted $target', () async {
        final directory = await Directory.systemTemp.createTemp('nn-quill-');
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/notes.sqlite');
        var session = _Session(file);
        addTearDown(() => session.close());
        final notebook = await session.repository.createNotebook();
        final bytes = Uint8List.fromList([2, 4, 6, 8]);
        final asset = VerifiedEditorAsset(
          assetId: 'recover-inline-asset',
          sha256: crypto.sha256.convert(bytes).toString(),
          sizeBytes: bytes.length,
          mediaType: type == 'pdf' ? 'application/pdf' : 'image/png',
        );
        session.buffer.stage(receipt: asset.attachPayload, bytes: bytes);
        final block = TextBlock(
          id: 'deleted-inline-text',
          text: 'Header\uFFFC\uFFFC',
          deltaJson: jsonEncode([
            {
              'insert': 'Header',
              'attributes': {'bold': true},
            },
            {
              'insert': {type: 'asset:${asset.assetId}'},
            },
            {
              'insert': {type: 'asset:${asset.assetId}'},
            },
            {'insert': '\n'},
          ]),
          position: const Offset(3, 4),
          fontSize: 18,
          color: const Color(0xFF123456),
          width: 210,
        );
        final page = notebook.pages.single.copyWith(
          id: 'deleted-inline-page',
          textBlocks: [block],
        );
        await session.writer.writeNotebookChange(
          before: notebook,
          after: notebook.copyWith(pages: [notebook.pages.single, page]),
          verifiedAssets: {asset.assetId: asset},
        );
        // Reopen with neither receipt registration nor staged bytes in memory.
        await session.close();
        session = _Session(file);
        final persisted = (await session.repository.getNotebook(notebook.uid))!;
        final originalDelta = persisted.pages.last.textBlocks.single.deltaJson;
        final controller = EditorController(
          repository: session.repository,
          notebook: persisted,
          operationWriter: session.writer,
        );
        addTearDown(controller.dispose);
        controller.setCurrentPage(1);
        if (target == 'page') {
          controller.deleteLastPage();
        } else if (target == 'block') {
          controller.deleteTextBlock(block.id);
        } else {
          controller.setActiveTextBlock(block.id, null);
          controller.updateTextBlockContent(
            controller.currentPage.textBlocks.single,
            plainText: 'Header',
            deltaJson: jsonEncode([
              {
                'insert': 'Header',
                'attributes': {'bold': true},
              },
              {'insert': '\n'},
            ]),
          );
          controller.setActiveTextBlock(null, null);
        }
        await controller.flushPendingSaves();
        expect(
          await session.database
              .customSelect('SELECT * FROM asset_references')
              .get(),
          isEmpty,
        );
        final deleted = (await session.store.pending()).last;
        controller.undo();
        await controller.flushPendingSaves();
        final restored = (await session.repository.getNotebook(notebook.uid))!;
        final restoredBlock = restored.pages.last.textBlocks.single;
        expect(
          restoredBlock.id,
          target == 'embed' ? block.id : isNot(block.id),
        );
        expect(restoredBlock.deltaJson, originalDelta);
        expect(restoredBlock.position, block.position);
        expect(
          restored.pages.last.id,
          target == 'page' ? isNot(page.id) : page.id,
        );
        expect(
          await session.projector.verifiedTextAssetBytes(
            documentId: notebook.uid,
            pageId: restored.pages.last.id,
            objectId: restoredBlock.id,
            assetId: asset.assetId,
          ),
          bytes,
        );
        final inverse = (await session.store.pending())
            .where(
              (operation) =>
                  operation.revertsOperationId == deleted.operationId,
            )
            .toList();
        expect(
          inverse.where((op) => op.kind == OperationKind.assetAttach),
          hasLength(1),
        );
        expect(
          inverse.indexWhere((op) => op.kind == OperationKind.assetAttach),
          lessThan(
            inverse.indexWhere((op) => op.kind == OperationKind.textInsert),
          ),
        );
        controller.redo();
        await controller.flushPendingSaves();
        if (target == 'embed') {
          expect(controller.pages.last.textBlocks.single.text, 'Header');
        } else {
          expect(controller.pages.expand((p) => p.textBlocks), isEmpty);
        }
        session.buffer.clear();
        controller.undo();
        await controller.flushPendingSaves();
        expect(
          controller.pages.last.textBlocks.single.id,
          target == 'embed' ? block.id : isNot(restoredBlock.id),
        );
        expect(
          controller.pages.last.textBlocks.single.deltaJson,
          originalDelta,
        );
      });
    }
  }

  test(
    'Quill recovery rejects another document and corrupt persisted bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nn-quill-scope-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final session = _Session(File('${directory.path}/notes.sqlite'));
      addTearDown(session.close);
      final notebook = await session.repository.createNotebook();
      final foreign = await session.repository.createNotebook();
      final bytes = Uint8List.fromList([1, 3, 5]);
      final asset = VerifiedEditorAsset(
        assetId: 'scoped-inline-asset',
        sha256: crypto.sha256.convert(bytes).toString(),
        sizeBytes: bytes.length,
        mediaType: 'image/png',
      );
      session.buffer.stage(receipt: asset.attachPayload, bytes: bytes);
      final block = TextBlock(
        id: 'scoped-inline-text',
        text: '\uFFFC',
        deltaJson: jsonEncode([
          {
            'insert': {'image': 'asset:${asset.assetId}'},
          },
          {'insert': '\n'},
        ]),
        position: Offset.zero,
        fontSize: 18,
        color: const Color(0xFF123456),
        width: 200,
      );
      final saved = notebook.copyWith(
        pages: [
          notebook.pages.single.copyWith(textBlocks: [block]),
        ],
      );
      await session.writer.writeNotebookChange(
        before: notebook,
        after: saved,
        verifiedAssets: {asset.assetId: asset},
      );
      await session.writer.writeNotebookChange(before: saved, after: notebook);
      session.buffer.clear();
      final count = (await session.store.pending()).length;
      await expectLater(
        session.writer.writeNotebookChange(
          before: foreign,
          after: foreign.copyWith(
            pages: [
              foreign.pages.single.copyWith(textBlocks: [block]),
            ],
          ),
        ),
        throwsStateError,
      );
      final wrongType = block.copyWith(
        deltaJson: jsonEncode([
          {
            'insert': {'pdf': 'asset:${asset.assetId}'},
          },
          {'insert': '\n'},
        ]),
      );
      await expectLater(
        session.writer.writeNotebookChange(
          before: notebook,
          after: notebook.copyWith(
            pages: [
              notebook.pages.single.copyWith(textBlocks: [wrongType]),
            ],
          ),
        ),
        throwsStateError,
      );
      expect(await session.store.pending(), hasLength(count));
      await session.database.customStatement(
        'UPDATE operation_asset_bytes SET bytes = ? WHERE checksum_sha256 = ?',
        [
          Uint8List.fromList([9, 9, 9]),
          asset.sha256,
        ],
      );
      await expectLater(
        session.writer.writeNotebookChange(
          before: notebook,
          after: notebook.copyWith(
            pages: [
              notebook.pages.single.copyWith(
                textBlocks: [block.copyWith(id: 'restored-inline-text')],
              ),
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(await session.store.pending(), hasLength(count));
      expect(
        (await session.repository.getNotebook(
          notebook.uid,
        ))!.pages.single.textBlocks,
        isEmpty,
      );
      expect(
        (await session.repository.getNotebook(
          foreign.uid,
        ))!.pages.single.textBlocks,
        isEmpty,
      );
      expect(
        await session.database
            .customSelect(
              'SELECT * FROM asset_references WHERE document_id = ?',
              variables: [Variable<String>(notebook.uid)],
            )
            .get(),
        isEmpty,
      );
    },
  );
}
