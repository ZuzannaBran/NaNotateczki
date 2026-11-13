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

  final importBytes = <String, List<int>>{
    'image/png': [137, 80, 78, 71, 13, 10, 26, 10, 1],
    'image/jpeg': [255, 216, 255, 1],
    'image/webp': [82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80],
    'application/pdf': [37, 80, 68, 70, 45, 49],
  };

  test(
    'removing one Quill embed preserves the other and recovery bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nn-quill-partial-detach-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/notes.sqlite');
      var session = _Session(file);
      addTearDown(() => session.close());
      final notebook = await session.repository.createNotebook();
      final imageBytes = Uint8List.fromList(importBytes['image/png']!);
      final pdfBytes = Uint8List.fromList(importBytes['application/pdf']!);
      final image = session.writer.stageQuillAsset(
        documentId: notebook.uid,
        bytes: imageBytes,
        embedType: 'image',
      );
      final pdf = session.writer.stageQuillAsset(
        documentId: notebook.uid,
        bytes: pdfBytes,
        embedType: 'pdf',
      );
      final block = TextBlock(
        id: 'partial-detach-text',
        text: 'A\uFFFC\uFFFC',
        deltaJson: jsonEncode([
          {'insert': 'A'},
          {
            'insert': {'image': 'asset:${image.assetId}'},
          },
          {
            'insert': {'pdf': 'asset:${pdf.assetId}'},
          },
          {'insert': '\n'},
        ]),
        position: Offset.zero,
        fontSize: 18,
        color: const Color(0xFF123456),
        width: 210,
      );
      await session.writer.writePageChange(
        documentId: notebook.uid,
        before: notebook.pages.single,
        after: notebook.pages.single.copyWith(textBlocks: [block]),
      );
      final original = (await session.repository.getNotebook(notebook.uid))!;
      final page = original.pages.single;
      final changed = page.copyWith(
        textBlocks: [
          page.textBlocks.single.copyWith(
            text: 'A\uFFFC',
            deltaJson: jsonEncode([
              {'insert': 'A'},
              {
                'insert': {'pdf': 'asset:${pdf.assetId}'},
              },
              {'insert': '\n'},
            ]),
          ),
        ],
      );
      final operations = await session.writer.writePageChange(
        documentId: notebook.uid,
        before: page,
        after: changed,
      );
      expect(
        operations
            .where((op) => op.kind == OperationKind.assetDetach)
            .map((op) => op.payload['assetId']),
        [image.assetId],
      );
      final refs = await session.database
          .customSelect(
            'SELECT asset_id FROM asset_references WHERE document_id = ?',
            variables: [Variable<String>(notebook.uid)],
          )
          .get();
      expect(refs.map((row) => row.read<String>('asset_id')), [pdf.assetId]);
      expect(
        await session.projector.verifiedTextAssetBytes(
          documentId: notebook.uid,
          pageId: page.id,
          objectId: block.id,
          assetId: pdf.assetId,
        ),
        orderedEquals(pdfBytes),
      );
      // Detached BLOBs must survive while journal uploads are pending.
      expect(
        await session.projector.verifiedUploadBytes(image.attachPayload),
        orderedEquals(imageBytes),
      );
      final pending = (await session.store.pending())
          .map((op) => op.operationId)
          .toList();
      await session.close();
      session = _Session(file);
      final reopened = (await session.repository.getNotebook(notebook.uid))!;
      expect(
        reopened.pages.single.textBlocks.single.deltaJson,
        changed.textBlocks.single.deltaJson,
      );
      expect(
        (await session.store.pending()).map((op) => op.operationId),
        pending,
      );
      expect(
        await session.projector.verifiedTextAssetBytes(
          documentId: notebook.uid,
          pageId: page.id,
          objectId: block.id,
          assetId: pdf.assetId,
        ),
        orderedEquals(pdfBytes),
      );
      expect(
        await session.projector.verifiedUploadBytes(image.attachPayload),
        orderedEquals(imageBytes),
      );
    },
  );

  for (final entry in importBytes.entries) {
    test(
      'new inline ${entry.key} survives Undo, Redo and a file restart',
      () async {
        final directory = await Directory.systemTemp.createTemp('nn-import-');
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/notes.sqlite');
        var session = _Session(file);
        addTearDown(() => session.close());
        final notebook = await session.repository.createNotebook();
        final original = TextBlock(
          id: 'inline-import-target',
          text: 'Before',
          deltaJson: jsonEncode([
            {'insert': 'Before\n'},
          ]),
          position: Offset.zero,
          fontSize: 18,
          color: const Color(0xFF123456),
          width: 200,
        );
        await session.writer.writePageChange(
          documentId: notebook.uid,
          before: notebook.pages.single,
          after: notebook.pages.single.copyWith(textBlocks: [original]),
        );
        final controller = EditorController(
          repository: session.repository,
          notebook: (await session.repository.getNotebook(notebook.uid))!,
          operationWriter: session.writer,
        );
        var disposed = false;
        addTearDown(() {
          if (!disposed) {
            controller.dispose();
          }
        });
        controller.setActiveTextBlock(original.id, null);
        final pendingBefore = (await session.store.pending()).length;
        final bytes = Uint8List.fromList(entry.value);
        final type = entry.key == 'application/pdf' ? 'pdf' : 'image';
        final reference = controller.prepareInlineAsset(
          blockId: original.id,
          bytes: bytes,
          embedType: type,
        );
        bytes[bytes.length - 1] ^= 1;
        expect(await session.store.pending(), hasLength(pendingBefore));
        expect(
          controller.currentPage.textBlocks.single.deltaJson,
          original.deltaJson,
        );
        controller.updateTextBlockContent(
          controller.currentPage.textBlocks.single,
          plainText: 'Before\uFFFC',
          deltaJson: jsonEncode([
            {'insert': 'Before'},
            {
              'insert': {type: reference},
            },
            {'insert': '\n'},
          ]),
        );
        await controller.flushPendingSaves();
        final added = (await session.store.pending())
            .skip(pendingBefore)
            .toList();
        expect(added.first.kind, OperationKind.assetAttach);
        expect(added.first.payload['mediaType'], entry.key);
        expect(
          added.first.payload['sha256'],
          crypto.sha256.convert(entry.value).toString(),
        );
        session.buffer.clear();
        controller.undo();
        await controller.flushPendingSaves();
        controller.redo();
        await controller.flushPendingSaves();
        final expected = controller.currentPage.textBlocks.single.deltaJson;
        final pendingIds = (await session.store.pending())
            .map((operation) => operation.operationId)
            .toList();
        controller.dispose();
        disposed = true;
        await session.close();
        session = _Session(file);
        final restored = (await session.repository.getNotebook(notebook.uid))!;
        expect(restored.pages.single.textBlocks.single.deltaJson, expected);
        expect(
          (await session.store.pending()).map((op) => op.operationId),
          pendingIds,
        );
        expect(
          await session.projector.verifiedTextAssetBytes(
            documentId: notebook.uid,
            pageId: restored.pages.single.id,
            objectId: original.id,
            assetId: reference.substring(6),
          ),
          entry.value,
        );
        final reopened = EditorController(
          repository: session.repository,
          notebook: restored,
          operationWriter: session.writer,
        );
        addTearDown(reopened.dispose);
        await reopened.historyReady;
        expect(reopened.canUndo, isTrue);
        reopened.undo();
        await reopened.flushPendingSaves();
        final undone = (await session.repository.getNotebook(notebook.uid))!;
        expect(
          undone.pages.single.textBlocks.single.deltaJson,
          original.deltaJson,
        );
        expect(reopened.canRedo, isTrue);
        reopened.redo();
        await reopened.flushPendingSaves();
        final redone = (await session.repository.getNotebook(notebook.uid))!;
        expect(redone.pages.single.textBlocks.single.deltaJson, expected);
        expect(
          await session.projector.verifiedTextAssetBytes(
            documentId: notebook.uid,
            pageId: redone.pages.single.id,
            objectId: original.id,
            assetId: reference.substring(6),
          ),
          entry.value,
        );
        final replayed = await session.store.pending();
        expect(replayed.length, greaterThan(pendingIds.length));
        expect(
          replayed.map((item) => item.operationId).toSet().length,
          replayed.length,
        );
      },
    );
  }

  test(
    'new inline import rolls back and retains verified staging for retry',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nn-import-retry-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final session = _Session(File('${directory.path}/notes.sqlite'));
      addTearDown(session.close);
      final notebook = await session.repository.createNotebook();
      final original = TextBlock(
        id: 'inline-retry-target',
        text: 'Before',
        deltaJson: jsonEncode([
          {'insert': 'Before\n'},
        ]),
        position: Offset.zero,
        fontSize: 18,
        color: const Color(0xFF123456),
        width: 200,
      );
      await session.writer.writePageChange(
        documentId: notebook.uid,
        before: notebook.pages.single,
        after: notebook.pages.single.copyWith(textBlocks: [original]),
      );
      final controller = EditorController(
        repository: session.repository,
        notebook: (await session.repository.getNotebook(notebook.uid))!,
        operationWriter: session.writer,
      );
      addTearDown(controller.dispose);
      controller.setActiveTextBlock(original.id, null);
      final pendingBefore = (await session.store.pending()).length;
      expect(
        () => controller.prepareInlineAsset(
          blockId: original.id,
          bytes: Uint8List(64 * 1024 * 1024 + 1),
          embedType: 'image',
        ),
        throwsArgumentError,
      );
      expect(
        () => controller.prepareInlineAsset(
          blockId: original.id,
          bytes: Uint8List.fromList(importBytes['image/png']!),
          embedType: 'pdf',
        ),
        throwsFormatException,
      );
      expect(
        () => controller.prepareInlineAsset(
          blockId: 'missing',
          bytes: Uint8List.fromList(importBytes['image/png']!),
          embedType: 'image',
        ),
        throwsStateError,
      );
      final reference = controller.prepareInlineAsset(
        blockId: original.id,
        bytes: Uint8List.fromList(importBytes['application/pdf']!),
        embedType: 'pdf',
      );
      final foreign = await session.repository.createNotebook();
      await expectLater(
        session.writer.writePageChange(
          documentId: foreign.uid,
          before: foreign.pages.single,
          after: foreign.pages.single.copyWith(
            textBlocks: [
              original.copyWith(
                id: 'foreign-import',
                text: '\uFFFC',
                deltaJson: jsonEncode([
                  {
                    'insert': {'pdf': reference},
                  },
                  {'insert': '\n'},
                ]),
              ),
            ],
          ),
        ),
        throwsStateError,
      );
      expect(await session.store.pending(), hasLength(pendingBefore));
      await session.database.customStatement('''
      CREATE TEMP TRIGGER reject_inline_attach BEFORE INSERT ON operations
      WHEN NEW.kind = 'asset.attach'
      BEGIN SELECT RAISE(ABORT, 'injected inline import failure'); END
    ''');
      controller.updateTextBlockContent(
        controller.currentPage.textBlocks.single,
        plainText: 'Before\uFFFC',
        deltaJson: jsonEncode([
          {'insert': 'Before'},
          {
            'insert': {'pdf': reference},
          },
          {'insert': '\n'},
        ]),
      );
      await expectLater(
        controller.flushPendingSaves(),
        throwsA(isA<DataIntegrityProtectionException>()),
      );
      expect(await session.store.pending(), hasLength(pendingBefore));
      expect(
        (await session.repository.getNotebook(
          notebook.uid,
        ))!.pages.single.textBlocks.single.deltaJson,
        original.deltaJson,
      );
      expect(
        await session.database
            .customSelect('SELECT * FROM asset_references')
            .get(),
        isEmpty,
      );
      expect(
        await session.database
            .customSelect('SELECT * FROM operation_asset_bytes')
            .get(),
        isEmpty,
      );
      await session.database.customStatement(
        'DROP TRIGGER reject_inline_attach',
      );
      await controller.flushPendingSaves();
      final added = (await session.store.pending())
          .skip(pendingBefore)
          .toList();
      expect(
        added.where((op) => op.kind == OperationKind.assetAttach),
        hasLength(1),
      );
      expect(
        added.first.actorSeq,
        (await session.store.pending()).elementAt(pendingBefore - 1).actorSeq +
            1,
      );
    },
  );

  for (final type in ['image', 'pdf']) {
    test(
      'toolbar styling retains $type embeds, atom IDs and unrelated styles',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'nn-quill-style-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final session = _Session(File('${directory.path}/notes.sqlite'));
        addTearDown(session.close);
        final notebook = await session.repository.createNotebook();
        final asset = session.writer.stageQuillAsset(
          documentId: notebook.uid,
          bytes: Uint8List.fromList(
            importBytes[type == 'pdf' ? 'application/pdf' : 'image/png']!,
          ),
          embedType: type,
        );
        final original = TextBlock(
          id: 'toolbar-rich-text',
          text: 'A\uFFFCB\nC',
          deltaJson: jsonEncode([
            {
              'insert': 'A',
              'attributes': {
                'bold': true,
                'link': 'https://example.test',
                'color': '#123456',
              },
            },
            {
              'insert': {type: 'asset:${asset.assetId}'},
            },
            {
              'insert': 'B',
              'attributes': {
                'italic': true,
                'font': 'Georgia',
                'color': '#654321',
              },
            },
            {
              'insert': '\n',
              'attributes': {'align': 'center'},
            },
            {
              'insert': 'C',
              'attributes': {'underline': true},
            },
            {
              'insert': '\n',
              'attributes': {'align': 'right'},
            },
          ]),
          position: Offset.zero,
          fontSize: 18,
          color: const Color(0xFF123456),
          width: 210,
        );
        await session.writer.writePageChange(
          documentId: notebook.uid,
          before: notebook.pages.single,
          after: notebook.pages.single.copyWith(textBlocks: [original]),
        );
        final persisted = (await session.repository.getNotebook(notebook.uid))!;
        final beforeDelta = persisted.pages.single.textBlocks.single.deltaJson!;
        final beforeAtoms = await session.store.textAtoms(
          documentId: notebook.uid,
          pageId: persisted.pages.single.id,
          objectId: original.id,
        );
        final controller = EditorController(
          repository: session.repository,
          notebook: persisted,
          operationWriter: session.writer,
        );
        addTearDown(controller.dispose);
        controller.setActiveTextBlock(original.id, null);
        session.buffer.clear();
        final pendingBefore = (await session.store.pending()).length;
        List<dynamic> delta() =>
            jsonDecode(controller.currentPage.textBlocks.single.deltaJson!)
                as List;
        Map attrs(String text) =>
            (delta().firstWhere(
                  (dynamic op) => op['insert'] == text,
                )['attributes']
                as Map? ??
            const {});
        controller.updateActiveTextStyle(fontSize: 22);
        await controller.flushPendingSaves();
        expect(attrs('A')['color'], '#123456');
        expect(attrs('B')['color'], '#654321');
        expect(attrs('C').containsKey('color'), isFalse);
        controller.undo();
        await controller.flushPendingSaves();
        expect(controller.currentPage.textBlocks.single.deltaJson, beforeDelta);
        controller.setActiveTextBlock(original.id, null);
        controller.updateActiveTextStyle(
          color: const Color(0xFFABCDEF),
          fontSize: 24,
        );
        await controller.flushPendingSaves();
        expect(attrs('A'), {
          'bold': true,
          'link': 'https://example.test',
          'color': '#abcdef',
          'size': '24',
        });
        expect(attrs('B'), {
          'italic': true,
          'font': 'Georgia',
          'color': '#abcdef',
          'size': '24',
        });
        expect(attrs('C')['underline'], isTrue);
        expect(
          delta().where((dynamic op) => op['insert'] is Map).single['insert'],
          {type: 'asset:${asset.assetId}'},
        );
        expect(
          delta()
              .where((dynamic op) => op['insert'] == '\n')
              .map((dynamic op) => op['attributes']['align']),
          ['center', 'right'],
        );
        final colored = controller.currentPage.textBlocks.single.deltaJson;
        controller.undo();
        await controller.flushPendingSaves();
        expect(controller.currentPage.textBlocks.single.deltaJson, beforeDelta);
        controller.redo();
        await controller.flushPendingSaves();
        expect(controller.currentPage.textBlocks.single.deltaJson, colored);
        controller.updateActiveTextStyle(
          targetBlockId: original.id,
          alignment: 'left',
        );
        await controller.flushPendingSaves();
        expect(attrs('A')['bold'], isTrue);
        expect(
          delta()
              .where((dynamic op) => op['insert'] == '\n')
              .every(
                (dynamic op) =>
                    !(op['attributes'] as Map? ?? {}).containsKey('align'),
              ),
          isTrue,
        );
        controller.updateActiveTextStyle(
          targetBlockId: original.id,
          clearDecorations: true,
          clearFontFamily: true,
        );
        await controller.flushPendingSaves();
        for (final dynamic op in delta()) {
          final attributes = op['attributes'] as Map? ?? const {};
          expect(
            attributes.keys.toSet().intersection({
              'bold',
              'italic',
              'underline',
              'strike',
              'font',
            }),
            isEmpty,
          );
        }
        expect(attrs('A')['link'], 'https://example.test');
        expect(attrs('B')['color'], '#abcdef');
        final atoms = await session.store.textAtoms(
          documentId: notebook.uid,
          pageId: persisted.pages.single.id,
          objectId: original.id,
        );
        expect(atoms.keys, unorderedEquals(beforeAtoms.keys));
        expect(
          atoms.values.where((dynamic atom) => atom['deleted'] == true),
          isEmpty,
        );
        final operations = (await session.store.pending()).skip(pendingBefore);
        expect(
          operations.any((op) => op.kind == OperationKind.textFormat),
          isTrue,
        );
        expect(
          operations.every(
            (op) =>
                op.kind == OperationKind.textFormat ||
                op.kind == OperationKind.objectSet,
          ),
          isTrue,
        );
        expect(
          await session.projector.verifiedTextAssetBytes(
            documentId: notebook.uid,
            pageId: persisted.pages.single.id,
            objectId: original.id,
            assetId: asset.assetId,
          ),
          importBytes[type == 'pdf' ? 'application/pdf' : 'image/png'],
        );
      },
    );
  }

  for (final type in ['image', 'pdf']) {
    for (final target in ['embed', 'block', 'page']) {
      test('offline $type Undo restores deleted $target', () async {
        final directory = await Directory.systemTemp.createTemp('nn-quill-');
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/notes.sqlite');
        var session = _Session(file);
        addTearDown(() => session.close());
        final notebook = await session.repository.createNotebook();
        final bytes = Uint8List.fromList(
          importBytes[type == 'pdf' ? 'application/pdf' : 'image/png']!,
        );
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
