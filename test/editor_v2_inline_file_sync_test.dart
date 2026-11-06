import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_history_store.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_asset_gateway.dart';
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
import 'package:program/features/notebook/domain/text_block.dart';

import 'support/native_test_documents.dart';

// A controlled HTTP boundary, not a substitute for the PostgreSQL E2E suite.
class _Transport {
  final accepted = <OperationEnvelope>[];
  final assets = <String, Uint8List>{};
  final mediaTypes = <String, String>{};
  final events = <String>[];
  bool loseNextAck = false;
  bool holdFeed = false;
  bool corruptDownload = false;

  http.Response json(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> handle(http.Request request) async {
    expect(request.headers['Authorization'], 'Bearer inline-test-account');
    if (request.url.path.startsWith('/v2/assets/')) {
      final digest = request.url.pathSegments.last;
      if (request.method == 'PUT') {
        expect(crypto.sha256.convert(request.bodyBytes).toString(), digest);
        final mime = request.headers['Content-Type']!;
        assets[digest] = Uint8List.fromList(request.bodyBytes);
        mediaTypes[digest] = mime;
        events.add('upload:$digest');
        return json({
          'sha256': digest,
          'sizeBytes': request.bodyBytes.length,
          'mediaType': mime,
        });
      }
      expect(request.method, 'GET');
      events.add('download:$digest');
      final bytes = assets[digest]!;
      return http.Response.bytes(
        corruptDownload ? List.filled(bytes.length, 0) : bytes,
        200,
        headers: {'content-type': mediaTypes[digest]!},
      );
    }
    if (request.method == 'POST' &&
        request.url.path == '/v2/operations/batch') {
      final body = jsonDecode(request.body) as Map;
      final acks = <Map<String, dynamic>>[];
      for (final raw in body['operations'] as List) {
        final operation = OperationEnvelope.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        operation.validateForV2Projection();
        if (operation.kind == OperationKind.assetAttach) {
          expect(assets, contains(operation.payload['sha256']));
          events.add('attach:${operation.payload['sha256']}');
        }
        final existing = accepted.indexWhere(
          (op) => op.operationId == operation.operationId,
        );
        if (existing < 0) {
          accepted.add(operation);
        }
        acks.add({
          'operationId': operation.operationId,
          'cursor': existing < 0 ? accepted.length : existing + 1,
          'status': existing < 0 ? 'applied' : 'duplicate',
        });
      }
      if (loseNextAck) {
        loseNextAck = false;
        holdFeed = true;
        throw const SocketException('Accepted batch, lost response.');
      }
      return json({
        'cursor': acks
            .map((ack) => ack['cursor'] as int)
            .reduce((a, b) => a > b ? a : b),
        'acknowledgements': acks,
      });
    }
    expect(request.method, 'GET');
    expect(request.url.path, '/v2/operations');
    final after = int.parse(request.url.queryParameters['after']!);
    return json({
      'cursor': holdFeed ? after : accepted.length,
      'hasMore': false,
      'operations': [
        if (!holdFeed)
          for (var i = after; i < accepted.length; i++)
            {'cursor': i + 1, 'operation': accepted[i].toJson()},
      ],
    });
  }
}

class _Peer {
  _Peer(File file, String actor, _Transport transport) {
    database = NotesDatabase(NativeDatabase(file));
    repository = NotebookRepository(database);
    store = OperationStore(database);
    projector = EditorSqliteProjector(database, verifiedAssetBuffer: buffer);
    api = ApiClient(
      baseUri: Uri.parse('https://inline.example.test'),
      httpClient: MockClient(transport.handle),
    )..setAccessToken('inline-test-account');
    final assets = OperationAssetGateway(api);
    engine = SyncEngine(
      store: store,
      gateway: HttpOperationGateway(api),
      actorId: actor,
      checkpointScope: 'inline-account',
      enableRealtime: false,
      pollInterval: const Duration(days: 1),
      applyRemote: (op, pending) async {
        if (pending.isNotEmpty) {
          throw StateError('Pending local operations');
        }
        await projector.apply(op);
      },
      prepareLocalOperations: (ops) =>
          assets.uploadPendingAssets(ops, projector.verifiedUploadBytes),
      prepareRemoteOperation: (op) => projector.prepareRemoteMedia(op, assets),
      onRemoteCommitted: (op) async {
        await beforeRemotePatch?.call(op);
        final target = editor;
        if (target != null) {
          await EditorV2RemotePatchDispatcher(
            editor: target,
            repository: repository,
          ).onRemoteCommitted(op);
        }
      },
    );
    writer = EditorV2OperationWriter(syncEngine: engine, projector: projector);
  }

  final buffer = VerifiedEditorAssetBuffer();
  late final NotesDatabase database;
  late final NotebookRepository repository;
  late final OperationStore store;
  late final EditorSqliteProjector projector;
  late final ApiClient api;
  late final SyncEngine engine;
  late final EditorV2OperationWriter writer;
  EditorController? editor;
  quill.QuillController? text;
  StreamSubscription<quill.DocChange>? subscription;
  Future<void> Function(OperationEnvelope)? beforeRemotePatch;
  bool closed = false;

  Future<void> openEditor(String documentId, {bool editing = false}) async {
    final notebook = (await repository.getNotebook(documentId))!;
    final controller = EditorController(
      repository: repository,
      notebook: notebook,
      operationWriter: writer,
      saveDebounce: const Duration(days: 1),
    );
    editor = controller;
    if (editing) {
      final block = notebook.pages.single.textBlocks.first;
      final quillController = quill.QuillController(
        document: quill.Document.fromJson(jsonDecode(block.deltaJson!) as List),
        selection: const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      text = quillController;
      controller.setActiveTextBlock(block.id, quillController);
      subscription = quillController.document.changes.listen((_) {
        controller.updateTextBlockContent(
          controller.findTextBlockById(block.id)!,
          plainText: quillController.document.toPlainText(),
          deltaJson: jsonEncode(quillController.document.toDelta().toJson()),
        );
      });
    }
    await flush();
  }

  Future<void> flush() async {
    await Future<void>.delayed(Duration.zero);
    await editor?.flushPendingSaves();
  }

  Future<void> close() async {
    if (closed) {
      return;
    }
    await engine.stop();
    await flush();
    await subscription?.cancel();
    editor?.dispose();
    text?.dispose();
    api.close();
    await database.close();
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  test(
    'new local gestures cannot revalidate history before a remote patch',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nn-history-peers-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final transport = _Transport();
      final firstFile = File('${directory.path}/first.sqlite');
      var first = _Peer(firstFile, 'history-first', transport);
      addTearDown(() => first.close());
      final second = _Peer(
        File('${directory.path}/second.sqlite'),
        'history-second',
        transport,
      );
      addTearDown(second.close);
      await first.repository.enableAccountOperations(first.writer);
      final notebook = await first.repository.createNotebook();
      await first.engine.start();
      await first.engine.stop();
      await first.openEditor(notebook.uid);
      first.editor!.addPage();
      await first.flush();
      final sharedPageId = first.editor!.currentPage.id;
      first.editor!.addInkStroke(const [InkPoint(dx: 1, dy: 1, pressure: 0.5)]);
      await first.flush();
      first.editor!.undo();
      await first.flush();
      expect(first.editor!.canUndo, isTrue);
      expect(first.editor!.canRedo, isTrue);
      await first.engine.start();
      await first.engine.stop();
      await second.engine.start();
      await second.engine.stop();
      await second.openEditor(notebook.uid);
      second.editor!.currentPageIndex = 1;
      second.editor!.addInkStroke(const [
        InkPoint(dx: 3, dy: 4, pressure: 0.5),
      ]);
      await second.flush();
      final remoteId = second.editor!.currentPage.inkStrokes.single.id;
      await second.engine.start();
      await second.engine.stop();
      final remoteOperation = transport.accepted.singleWhere(
        (op) => op.objectId == remoteId,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      first.beforeRemotePatch = (op) async {
        if (op.operationId == remoteOperation.operationId) {
          entered.complete();
          await release.future;
        }
      };
      final pull = first.engine.start();
      try {
        await entered.future.timeout(const Duration(seconds: 10));
        final editor = first.editor!;
        expect(editor.canUndo, isTrue);
        expect(editor.canRedo, isTrue);
        editor.viewScale = 1.7;
        editor.viewPan = const Offset(17, -21);
        expect(editor.currentPage.inkStrokes, isEmpty);
        for (var i = 0; i < 2; i++) {
          editor.addInkStroke([InkPoint(dx: 8.0 + i, dy: 9, pressure: 0.6)]);
          await first.flush();
          expect(editor.canUndo, isFalse);
          expect(editor.canRedo, isFalse);
        }
        final pending = (await first.store.pending())
            .map((op) => op.operationId)
            .toList();
        expect(pending, hasLength(2));
        final checkpoint = (await EditorHistoryStore(first.store).load(
          documentId: notebook.uid,
          ownerId: first.engine.actorIdForDocument(notebook.uid),
        ))!;
        expect(checkpoint.undo, isEmpty);
        expect(checkpoint.redo, isEmpty);
        editor.undo();
        await first.flush();
        expect(
          (await first.store.pending()).map((op) => op.operationId),
          pending,
        );
        expect(
          await first.store.isTombstoned(notebook.uid, 'page', sharedPageId),
          isFalse,
        );
        final durable = (await first.repository.getNotebook(notebook.uid))!;
        expect(
          durable.pages.last.inkStrokes.map((stroke) => stroke.id),
          contains(remoteId),
        );
        expect(durable.pages.last.inkStrokes, hasLength(3));
      } finally {
        release.complete();
        await pull;
        first.beforeRemotePatch = null;
      }
      await first.engine.stop();
      final editor = first.editor!;
      expect(editor.currentPage.inkStrokes, hasLength(3));
      expect(
        editor.currentPage.inkStrokes.map((stroke) => stroke.id),
        contains(remoteId),
      );
      expect(editor.viewScale, 1.7);
      expect(editor.viewPan, const Offset(17, -21));
      expect(second.editor!.viewScale, 1);
      expect(second.editor!.viewPan, Offset.zero);
      editor.addInkStroke(const [InkPoint(dx: 20, dy: 21, pressure: 0.6)]);
      await first.flush();
      expect(editor.canUndo, isTrue);
      final added = editor.currentPage.inkStrokes.last.id;
      await first.close();
      first = _Peer(firstFile, 'history-first', transport);
      await first.openEditor(notebook.uid);
      expect(first.editor!.canUndo, isTrue);
      first.editor!.undo();
      await first.flush();
      final preserved = first.editor!.pages.last.inkStrokes;
      expect(preserved, hasLength(3));
      expect(preserved.map((stroke) => stroke.id), contains(remoteId));
      expect(preserved.map((stroke) => stroke.id), isNot(contains(added)));
      first.editor!.redo();
      await first.flush();
      expect(first.editor!.pages.last.inkStrokes, hasLength(4));
      await first.engine.start();
      await first.engine.stop();
      await second.engine.start();
      await second.engine.stop();
      expect(
        second.editor!.pages.last.inkStrokes.map((stroke) => stroke.id).toSet(),
        first.editor!.pages.last.inkStrokes.map((stroke) => stroke.id).toSet(),
      );
      expect(
        transport.accepted.map((op) => op.operationId).toSet(),
        hasLength(transport.accepted.length),
      );
    },
  );

  for (final type in ['image', 'pdf']) {
    test(
      '$type inline import survives restarts and lost ACK across two SQLite peers',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'nn-inline-peers-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final transport = _Transport();
        final file = File('${directory.path}/first.sqlite');
        var first = _Peer(file, 'inline-first', transport);
        addTearDown(() => first.close());
        final second = _Peer(
          File('${directory.path}/second.sqlite'),
          'inline-second',
          transport,
        );
        addTearDown(second.close);
        await first.repository.enableAccountOperations(first.writer);
        final notebook = await first.repository.createNotebook();
        TextBlock block(String id, String value) => TextBlock(
          id: id,
          text: value,
          deltaJson: jsonEncode([
            {'insert': '$value\n'},
          ]),
          position: Offset.zero,
          fontSize: 18,
          color: const Color(0xFF123456),
          width: 220,
        );
        await first.writer.writePageChange(
          documentId: notebook.uid,
          before: notebook.pages.single,
          after: notebook.pages.single.copyWith(
            textBlocks: [
              block('inline-target', 'KeepOriginal'),
              block('untouched', 'Other text'),
            ],
          ),
        );
        await first.engine.start();
        expect(first.engine.lastError, isNull);
        await first.engine.stop();
        await second.engine.start();
        expect(second.engine.lastError, isNull);
        await second.engine.stop();
        await second.openEditor(notebook.uid);
        final receiver = second.editor!;
        receiver.viewScale = 1.75;
        receiver.viewPan = const Offset(41, -23);
        final untouched = receiver.currentPage.textBlocks.last;
        await first.openEditor(notebook.uid, editing: true);
        final bytes = Uint8List.fromList(
          type == 'pdf'
              ? [37, 80, 68, 70, 45, 49]
              : [137, 80, 78, 71, 13, 10, 26, 10, 1],
        );
        final beforeRequests = transport.events.length;
        await first.editor!.insertQuillFile(
          blockId: 'inline-target',
          readBytes: () async => bytes,
        );
        await first.flush();
        expect(transport.events.length, beforeRequests);
        final expected = first.editor!.currentPage.textBlocks.first.deltaJson;
        final pendingIds = (await first.store.pending())
            .map((op) => op.operationId)
            .toList();
        expect(pendingIds, isNotEmpty);
        await first.close();
        first = _Peer(file, 'inline-first', transport);
        expect(
          (await first.store.pending()).map((op) => op.operationId),
          pendingIds,
        );
        await first.openEditor(notebook.uid);
        expect(first.editor!.currentPage.textBlocks.first.deltaJson, expected);
        transport.loseNextAck = true;
        await first.engine.start();
        expect(transport.loseNextAck, isFalse);
        expect(transport.holdFeed, isTrue);
        expect(
          transport.accepted.map((op) => op.operationId),
          containsAll(pendingIds),
        );
        // An actor retry is durable even if the completed drain clears its
        // transient global error. Deferred entries are not eligible to send.
        expect(
          (await first.store.pending(
            includeDeferred: true,
          )).map((op) => op.operationId),
          pendingIds,
        );
        final retry = await first.database
            .customSelect(
              'SELECT attempts, status FROM operation_outbox WHERE operation_id = ?',
              variables: [Variable<String>(pendingIds.first)],
            )
            .getSingle();
        expect(retry.read<int>('attempts'), greaterThanOrEqualTo(1));
        expect(retry.read<String>('status'), 'queued');
        await first.close();
        first = _Peer(file, 'inline-first', transport);
        await first.openEditor(notebook.uid);
        final localPage = first.editor!.currentPage;
        var repaints = 0;
        first.editor!.addListener(() => repaints++);
        transport.holdFeed = false;
        await first.engine.start();
        expect(first.engine.lastError, isNull);
        expect(await first.store.pending(), isEmpty);
        expect(identical(first.editor!.currentPage, localPage), isTrue);
        expect(repaints, 0);
        final attach = transport.accepted.singleWhere(
          (op) => op.kind == OperationKind.assetAttach,
        );
        final digest = attach.payload['sha256'] as String;
        expect(
          transport.events.indexOf('upload:$digest'),
          lessThan(transport.events.indexOf('attach:$digest')),
        );

        // A corrupt response must not make the remote embed visible or skip its cursor.
        transport.corruptDownload = true;
        await second.engine.start();
        expect(second.engine.lastError, isNotNull);
        expect(
          receiver.currentPage.textBlocks.first.deltaJson,
          isNot(expected),
        );
        transport.corruptDownload = false;
        await second.engine.syncNow();
        expect(second.engine.lastError, isNull);
        expect(receiver.currentPage.textBlocks.first.deltaJson, expected);
        expect(
          identical(receiver.currentPage.textBlocks.last, untouched),
          isTrue,
        );
        expect(receiver.viewScale, 1.75);
        expect(receiver.viewPan, const Offset(41, -23));
        expect(
          await second.projector.verifiedTextAssetBytes(
            documentId: notebook.uid,
            pageId: receiver.currentPage.id,
            objectId: 'inline-target',
            assetId: attach.payload['assetId'] as String,
          ),
          bytes,
        );
        expect(await second.store.pending(), isEmpty);
        expect(
          transport.accepted.map((op) => op.operationId).toSet(),
          hasLength(transport.accepted.length),
        );

        await second.engine.stop();
        receiver.deleteTextBlock('inline-target');
        await second.flush();
        await second.engine.start();
        await first.engine.syncNow();
        expect(first.engine.lastError, isNull);
        expect(first.editor!.findTextBlockById('inline-target'), isNull);
        expect(first.editor!.currentPage.textBlocks.single.id, 'untouched');

        await second.engine.stop();
        second.buffer.clear();
        receiver.undo();
        await second.flush();
        final restored = receiver.currentPage.textBlocks.firstWhere(
          (block) => block.id != 'untouched',
        );
        expect(restored.id, isNot('inline-target'));
        expect(restored.deltaJson, expected);
        await second.engine.start();
        await first.engine.syncNow();
        expect(first.engine.lastError, isNull);
        expect(
          first.editor!.findTextBlockById(restored.id)?.deltaJson,
          expected,
        );
        expect(
          await first.projector.verifiedTextAssetBytes(
            documentId: notebook.uid,
            pageId: first.editor!.currentPage.id,
            objectId: restored.id,
            assetId: attach.payload['assetId'] as String,
          ),
          bytes,
        );
        final acceptedCount = transport.accepted.length;
        await second.engine.syncNow();
        await first.engine.syncNow();
        expect(transport.accepted, hasLength(acceptedCount));
        expect(receiver.viewScale, 1.75);
        expect(receiver.viewPan, const Offset(41, -23));
      },
    );
  }
}
