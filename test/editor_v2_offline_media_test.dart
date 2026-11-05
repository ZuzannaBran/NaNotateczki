import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_asset_gateway.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/data/sync/verified_editor_asset_buffer.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/text_block.dart';

class _AcknowledgingGateway implements OperationGateway {
  _AcknowledgingGateway(this.events);
  final List<String> events;
  final List<SequencedOperation> accepted = [];
  bool loseNextAck = false;
  bool holdFeed = false;

  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    if (operations.any((op) => op.kind == OperationKind.assetAttach)) {
      expect(events, contains('upload'));
    }
    events.add('operations');
    final receipts = <OperationReceipt>[];
    for (final operation in operations) {
      final existing = accepted.where(
        (entry) => entry.operation.operationId == operation.operationId,
      );
      final cursor = existing.isEmpty
          ? accepted.length + 1
          : existing.single.cursor;
      if (existing.isEmpty) {
        accepted.add(SequencedOperation(cursor, operation));
      }
      receipts.add(OperationReceipt(operation.operationId, cursor));
    }
    if (loseNextAck) {
      loseNextAck = false;
      holdFeed = true;
      throw const SocketException('Committed but response lost.');
    }
    return receipts;
  }

  @override
  Future<OperationFeedPage> readAfter(int cursor) async => OperationFeedPage(
    cursor: holdFeed ? cursor : accepted.length,
    hasMore: false,
    operations: holdFeed
        ? []
        : accepted.where((op) => op.cursor > cursor).toList(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'twenty-page offline notebook reopens after mixed content deletion',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nn-twenty-pages-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/notes.sqlite');
      final database = NotesDatabase(NativeDatabase(file));
      final repository = NotebookRepository(database);
      final events = <String>[];
      final projector = EditorSqliteProjector(
        database,
        verifiedAssetBuffer: VerifiedEditorAssetBuffer(),
      );
      final engine = SyncEngine(
        store: OperationStore(database),
        gateway: _AcknowledgingGateway(events),
        actorId: 'offline-book',
        checkpointScope: 'offline-book',
        enableRealtime: false,
        applyRemote: (operation, _) => projector.apply(operation),
      );
      final writer = EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
      );
      await repository.enableAccountOperations(writer);
      final notebook = await repository.createNotebook();
      final template = notebook.pages.single;
      final pages = List.generate(
        20,
        (index) => template.copyWith(
          id: index == 0 ? template.id : 'offline-page-$index',
          title: 'Page ${index + 1}',
          inkStrokes: [
            InkStroke(
              id: 'offline-ink-$index',
              color: const Color(0xFF112233),
              width: 2,
              tool: DrawingTool.pen,
              points: [InkPoint(dx: index.toDouble(), dy: 4, pressure: 0.5)],
            ),
          ],
          textBlocks: [
            TextBlock(
              id: 'offline-text-$index',
              text: 'Page $index',
              deltaJson: jsonEncode([
                {
                  'insert': 'Page $index',
                  'attributes': {'bold': true},
                },
                {'insert': '\n'},
              ]),
              position: const Offset(10, 20),
              fontSize: 18,
              color: const Color(0xFF112233),
              width: 200,
            ),
          ],
          imageBlocks: [
            ImageBlock(
              id: 'offline-media-$index',
              path: '',
              ocrText: '',
              bytes: Uint8List.fromList([1, 2, 3, index]),
              imageExt: index.isEven ? 'png' : 'pdf',
              imageMime: index.isEven ? 'image/png' : 'application/pdf',
              position: const Offset(30, 40),
              width: 120,
              height: 80,
            ),
          ],
        ),
      );
      await writer.writeNotebookChange(
        before: notebook,
        after: notebook.copyWith(pages: pages),
      );
      final populated = (await repository.getNotebook(notebook.uid))!;
      expect(populated.pages, hasLength(20));
      final retained = [
        for (var i = 0; i < populated.pages.length; i++)
          if (i % 4 != 0) populated.pages[i],
      ];
      await writer.writeNotebookChange(
        before: populated,
        after: populated.copyWith(pages: retained),
      );
      final expected = (await repository.getNotebook(notebook.uid))!;
      expect(expected.pages, hasLength(15));
      final expectedDocument = repository.encodeNotebooks([expected]).single;
      final pending = (await engine.store.pending(
        limit: 1000,
        includeDeferred: true,
      )).map((op) => op.operationId).toList();
      expect(events, isEmpty);
      await engine.stop();
      await database.close();

      final reopened = NotesDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      final reopenedRepository = NotebookRepository(reopened);
      final loaded = (await reopenedRepository.getNotebook(notebook.uid))!;
      expect(
        reopenedRepository.encodeNotebooks([loaded]).single,
        expectedDocument,
      );
      expect(
        (await OperationStore(reopened).pending(
          limit: 1000,
          includeDeferred: true,
        )).map((op) => op.operationId),
        pending,
      );
    },
  );

  for (final mime in ['image/png', 'application/pdf']) {
    for (final deleteBeforeRestart in [false, true]) {
      test(
        'offline $mime survives reopen, deleted=$deleteBeforeRestart',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'nn-offline-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = File('${directory.path}/notes.sqlite');
          final events = <String>[];
          final transport = _AcknowledgingGateway(events);
          final first = NotesDatabase(NativeDatabase(file));
          final repository = NotebookRepository(first);
          final store = OperationStore(first);
          final projector = EditorSqliteProjector(
            first,
            verifiedAssetBuffer: VerifiedEditorAssetBuffer(),
          );
          final engine = SyncEngine(
            store: store,
            gateway: transport,
            actorId: 'offline-media',
            checkpointScope: 'offline-media',
            enableRealtime: false,
            applyRemote: (operation, _) => projector.apply(operation),
          );
          final writer = EditorV2OperationWriter(
            syncEngine: engine,
            projector: projector,
          );
          await repository.enableAccountOperations(writer);
          final notebook = await repository.createNotebook();
          final page = notebook.pages.single;
          final bytes = Uint8List.fromList([1, 3, 7, 15]);
          final changed = page.copyWith(
            imageBlocks: [
              ImageBlock(
                id: 'offline-image',
                path: '',
                ocrText: '',
                bytes: bytes,
                imageMime: mime,
                imageExt: mime == 'application/pdf' ? 'pdf' : 'png',
                position: const Offset(11, 22),
                width: 120,
                height: 80,
              ),
            ],
          );
          await writer.writePageChange(
            documentId: notebook.uid,
            before: page,
            after: changed,
          );
          if (deleteBeforeRestart) {
            await writer.writePageChange(
              documentId: notebook.uid,
              before: changed,
              after: page,
            );
          }
          final pendingIds = (await store.pending(
            includeDeferred: true,
          )).map((op) => op.operationId).toList();
          expect(events, isEmpty);
          await engine.stop();
          await first.close();

          final reopened = NotesDatabase(NativeDatabase(file));
          var databaseToClose = reopened;
          addTearDown(() => databaseToClose.close());
          final recoveredStore = OperationStore(reopened);
          final recoveredProjector = EditorSqliteProjector(reopened);
          final recovered = (await NotebookRepository(
            reopened,
          ).getNotebook(notebook.uid))!;
          expect(
            recovered.pages.single.imageBlocks,
            hasLength(deleteBeforeRestart ? 0 : 1),
          );
          if (!deleteBeforeRestart) {
            expect(
              recovered.pages.single.imageBlocks.single.bytes,
              orderedEquals(bytes),
            );
          }
          expect(
            (await recoveredStore.pending(
              includeDeferred: true,
            )).map((op) => op.operationId),
            pendingIds,
          );
          var offline = true;
          final api = ApiClient(
            baseUri: Uri.parse('https://api.example.test'),
            httpClient: MockClient((request) async {
              if (offline) {
                throw const SocketException('Offline');
              }
              events.add('upload');
              expect(request.bodyBytes, orderedEquals(bytes));
              expect(
                request.url.path,
                '/v2/assets/${crypto.sha256.convert(bytes)}',
              );
              return http.Response(
                jsonEncode({
                  'sha256': crypto.sha256.convert(bytes).toString(),
                  'sizeBytes': bytes.length,
                  'mediaType': mime,
                }),
                200,
              );
            }),
          );
          api.setAccessToken('test-token');
          addTearDown(api.close);
          final assets = OperationAssetGateway(api);
          final attachments = (await recoveredStore.pending(
            includeDeferred: true,
          )).where((op) => op.kind == OperationKind.assetAttach).toList();
          await reopened.customStatement(
            'UPDATE operation_asset_bytes SET bytes = ?',
            [
              Uint8List.fromList([99]),
            ],
          );
          await expectLater(
            assets.uploadPendingAssets(
              attachments,
              recoveredProjector.verifiedUploadBytes,
            ),
            throwsFormatException,
          );
          expect(events, isEmpty);
          await reopened.customStatement(
            'UPDATE operation_asset_bytes SET bytes = ?',
            [bytes],
          );
          final recoveredEngine = SyncEngine(
            store: recoveredStore,
            gateway: transport,
            actorId: 'offline-media',
            checkpointScope: 'offline-media',
            enableRealtime: false,
            applyRemote: (operation, _) => recoveredProjector.apply(operation),
            prepareLocalOperations: (operations) => assets.uploadPendingAssets(
              operations,
              recoveredProjector.verifiedUploadBytes,
            ),
          );
          addTearDown(recoveredEngine.stop);
          await recoveredEngine.start();
          expect(events, isEmpty);
          expect(
            await recoveredStore.pending(includeDeferred: true),
            hasLength(pendingIds.length),
          );
          offline = false;
          transport.loseNextAck = true;
          await reopened.customStatement(
            'UPDATE operation_outbox SET retry_after = 0',
          );
          await recoveredEngine.syncNow();
          expect(events, ['upload', 'operations']);
          expect(
            await recoveredStore.pending(includeDeferred: true),
            hasLength(pendingIds.length),
          );
          await recoveredEngine.stop();
          await reopened.close();

          // The server committed, but no operation ACK reached this database.
          databaseToClose = NotesDatabase(NativeDatabase(file));
          final afterCrashStore = OperationStore(databaseToClose);
          final afterCrashProjector = EditorSqliteProjector(databaseToClose);
          final afterCrashEngine = SyncEngine(
            store: afterCrashStore,
            gateway: transport,
            actorId: 'offline-media',
            checkpointScope: 'offline-media',
            enableRealtime: false,
            applyRemote: (operation, _) => afterCrashProjector.apply(operation),
            prepareLocalOperations: (operations) => assets.uploadPendingAssets(
              operations,
              afterCrashProjector.verifiedUploadBytes,
            ),
          );
          addTearDown(afterCrashEngine.stop);
          transport.holdFeed = false;
          await afterCrashEngine.start();
          expect(await afterCrashStore.pending(includeDeferred: true), isEmpty);
          expect(
            transport.accepted.map((op) => op.operation.operationId),
            pendingIds,
          );
        },
      );
    }
  }
}
