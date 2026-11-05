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
import 'package:program/features/notebook/domain/image_block.dart';

class _AcknowledgingGateway implements OperationGateway {
  _AcknowledgingGateway(this.events);
  final List<String> events;
  final List<SequencedOperation> accepted = [];

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
      final cursor = accepted.length + 1;
      accepted.add(SequencedOperation(cursor, operation));
      receipts.add(OperationReceipt(operation.operationId, cursor));
    }
    return receipts;
  }

  @override
  Future<OperationFeedPage> readAfter(int cursor) async => OperationFeedPage(
    cursor: accepted.length,
    hasMore: false,
    operations: accepted.where((op) => op.cursor > cursor).toList(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
          addTearDown(reopened.close);
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
          await reopened.customStatement(
            'UPDATE operation_outbox SET retry_after = 0',
          );
          await recoveredEngine.syncNow();
          expect(events, ['upload', 'operations']);
          expect(await recoveredStore.pending(includeDeferred: true), isEmpty);
          expect(
            transport.accepted.map((op) => op.operation.operationId),
            pendingIds,
          );
        },
      );
    }
  }
}
