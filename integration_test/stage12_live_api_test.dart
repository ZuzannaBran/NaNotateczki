import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_v2_account_runtime.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/text_block.dart';

import '../test/support/native_test_documents.dart';

const _baseUrl = String.fromEnvironment('NN_STAGE12_API_URL');
const _token = String.fromEnvironment('NN_STAGE12_ACCESS_TOKEN');
final _media = <String, Uint8List>{
  'image': base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
    'AAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg==',
  ),
};

class _Peer {
  _Peer(File file, String actor, String account) {
    database = NotesDatabase(NativeDatabase(file));
    repository = NotebookRepository(database);
    api = ApiClient(baseUri: Uri.parse(_baseUrl))..setAccessToken(_token);
    runtime = EditorV2AccountRuntime(
      repository: repository,
      apiClient: api,
      accountId: account,
      actorId: actor,
    );
  }

  late final NotesDatabase database;
  late final NotebookRepository repository;
  late final ApiClient api;
  late final EditorV2AccountRuntime runtime;
  EditorController? editor;
  bool _closed = false;

  Future<void> initialize() =>
      repository.enableAccountOperations(runtime.writer);

  Future<void> openEditor(String documentId) async {
    final controller = EditorController(
      repository: repository,
      notebook: (await repository.getNotebook(documentId))!,
      operationWriter: runtime.writer,
      saveDebounce: const Duration(days: 1),
    );
    editor = controller;
    runtime.attachEditor(controller);
    await controller.historyReady;
    await controller.preferencesReady;
  }

  Future<void> flush() async {
    await editor!.flushPendingSaves();
  }

  Future<void> sync({bool start = false}) async {
    if (start) {
      await runtime.start();
    } else {
      await runtime.engine.syncNow();
    }
    expect(runtime.engine.lastError, isNull);
    expect(await runtime.store.pending(includeDeferred: true), isEmpty);
  }

  Future<void> restartSync() async {
    await runtime.stop();
    await sync(start: true);
  }

  Future<void> waitFor(bool Function() condition, String reason) async {
    final changed = Completer<void>();
    void check() {
      if (!changed.isCompleted && condition()) {
        changed.complete();
      }
    }

    editor!.addListener(check);
    check();
    try {
      // Less than the production poll interval: no manual receiver sync.
      await changed.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw StateError(
          '$reason; receiver error: ${runtime.engine.lastError}',
        ),
      );
    } finally {
      editor!.removeListener(check);
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await runtime.stop();
      await editor?.flushPendingSaves();
    } finally {
      final controller = editor;
      if (controller != null) {
        runtime.detachEditor(controller);
        controller.dispose();
      }
      runtime.dispose();
      api.close();
      await database.close();
    }
  }
}

String _assetId(TextBlock block, String type) {
  final delta = jsonDecode(block.deltaJson!) as List;
  final embed = delta.singleWhere((dynamic op) => op['insert'] is Map) as Map;
  return ((embed['insert'] as Map)[type] as String).substring(6);
}

bool _hasMedia(_Peer peer) {
  final pages = peer.editor!.pages;
  return pages.length == 2 &&
      pages.last.textBlocks.length == 2 &&
      pages.last.textBlocks.every((block) {
        final delta = block.deltaJson ?? '';
        return delta.contains('asset:') &&
            delta.contains('"bold":true') &&
            delta.contains('"italic":true');
      });
}

Future<void> _expectMedia(_Peer peer) async {
  final editor = peer.editor!;
  final page = editor.pages.last;
  expect(page.textBlocks, hasLength(2));
  for (final type in _media.keys) {
    final block = page.textBlocks.singleWhere((b) => b.text.startsWith(type));
    expect(block.text, contains(' tail'));
    expect(block.deltaJson, contains('"bold":true'));
    expect(block.deltaJson, contains('"italic":true'));
    expect(
      await peer.runtime.projector.verifiedTextAssetBytes(
        documentId: editor.notebook.uid,
        pageId: page.id,
        objectId: block.id,
        assetId: _assetId(block, type),
      ),
      _media[type],
    );
  }
  final references = await peer.database
      .customSelect(
        'SELECT object_id FROM asset_references WHERE document_id = ?',
        variables: [Variable<String>(editor.notebook.uid)],
      )
      .get();
  expect(references.map((row) => row.read<String>('object_id')).toSet(), {
    for (final block in page.textBlocks)
      'page:${jsonEncode([page.id, block.id])}',
  });
  expect(references, hasLength(2));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  testWidgets(
    'controllers recover offline media and page Undo through real API and SQL',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        final endpoint = Uri.parse(_baseUrl);
        expect(endpoint.scheme, 'http');
        expect(endpoint.host, anyOf('127.0.0.1', 'localhost', '::1'));
        expect(_token, isNotEmpty, reason: 'Use scripts/run-stage12-real.sh');
        final pdf = pw.Document()
          ..addPage(pw.Page(build: (_) => pw.Text('Offline PDF')));
        _media['pdf'] = await pdf.save();
        final directory = await Directory.systemTemp.createTemp('nn-live-v2-');
        addTearDown(() => directory.delete(recursive: true));
        final identityApi = ApiClient(baseUri: endpoint)
          ..setAccessToken(_token);
        late final String account;
        try {
          final profile =
              (await identityApi.get('/v1/auth/me')).decodeJson() as Map;
          account = profile['userId'] as String;
        } finally {
          identityApi.close();
        }
        final firstFile = File('${directory.path}/first.sqlite');
        final secondFile = File('${directory.path}/second.sqlite');
        var first = _Peer(firstFile, 'live-first', account);
        var second = _Peer(secondFile, 'live-second', account);
        addTearDown(() => first.close());
        addTearDown(() => second.close());
        await first.initialize();
        await second.initialize();
        final notebook = await first.repository.createNotebook(
          title: 'Live v2',
        );
        await first.sync(start: true);
        await second.sync(start: true);
        await first.openEditor(notebook.uid);
        await second.openEditor(notebook.uid);
        second.editor!.viewScale = 1.7;
        second.editor!.viewPan = const Offset(19, -23);

        first.editor!.setTool(DrawingTool.pen);
        first.editor!.addInkStroke(const [
          InkPoint(dx: 10, dy: 20, pressure: 0.6),
        ]);
        await first.flush();
        await first.sync();
        final strokeId = first.editor!.currentPage.inkStrokes.single.id;
        await second.waitFor(
          () => second.editor!.currentPage.inkStrokes.any(
            (s) => s.id == strokeId,
          ),
          'WebSocket did not deliver the first real controller gesture',
        );
        expect(second.editor!.viewScale, 1.7);
        expect(second.editor!.viewPan, const Offset(19, -23));

        // Commit offline, then remove the entire client before any media upload.
        await first.runtime.stop();
        first.editor!.addPage();
        await first.flush();
        final deletedPageId = first.editor!.currentPage.id;
        for (final type in _media.keys) {
          first.editor!.addTextBlockFromText(
            const Offset(20, 40),
            '$type tail',
          );
          await first.flush();
          final block = first.editor!.currentPage.textBlocks.last;
          first.editor!.updateTextBlockContent(
            block,
            plainText: '$type tail',
            deltaJson: jsonEncode([
              {
                'insert': type,
                'attributes': {'bold': true},
              },
              {
                'insert': ' tail',
                'attributes': {'italic': true},
              },
              {'insert': '\n'},
            ]),
          );
          await first.flush();
          first.editor!.setTool(DrawingTool.text);
          first.editor!.setActiveTextBlock(block.id, null);
          final hud = TextEditingController(text: '$type tail')
            ..selection = TextSelection.collapsed(offset: type.length);
          first.editor!.bindHudTextController(block.id, hud);
          try {
            expect(
              await first.editor!.insertQuillFile(
                blockId: block.id,
                readBytes: () async => _media[type]!,
              ),
              isTrue,
            );
          } finally {
            first.editor!.unbindHudTextController(block.id, hud);
            hud.dispose();
          }
          first.editor!.clearActiveTextBlock();
          await first.flush();
        }
        await _expectMedia(first);
        final pendingBeforeRestart = (await first.runtime.store.pending(
          includeDeferred: true,
        )).map((op) => op.operationId).toList();
        expect(pendingBeforeRestart, isNotEmpty);
        await first.close();
        first = _Peer(firstFile, 'live-first', account);
        await first.initialize();
        await first.openEditor(notebook.uid);
        expect(
          (await first.runtime.store.pending(
            includeDeferred: true,
          )).map((op) => op.operationId),
          pendingBeforeRestart,
        );
        await _expectMedia(first);
        expect(first.editor!.canUndo, isTrue);
        // Reset the receiver's poll before the sender can upload. Each
        // delivery deadline then precedes the production 45-second timer.
        await second.restartSync();
        await first.sync(start: true);
        expect(first.editor!.canUndo, isTrue);
        await second.waitFor(
          () => _hasMedia(second),
          'Remote rich media did not arrive after the offline restart',
        );
        await _expectMedia(second);
        await second.sync();
        expect(second.editor!.viewScale, 1.7);
        expect(second.editor!.viewPan, const Offset(19, -23));

        // A deleted page must stay deleted after restarting the deleting client.
        await second.runtime.stop();
        second.editor!.deleteLastPage();
        await second.flush();
        await second.close();
        second = _Peer(secondFile, 'live-second', account);
        await second.initialize();
        await second.openEditor(notebook.uid);
        expect(second.editor!.pages, hasLength(1));
        expect(second.editor!.canUndo, isTrue);
        await first.restartSync();
        expect(first.editor!.pages, hasLength(2));
        await second.sync(start: true);
        expect(second.editor!.canUndo, isTrue);
        await first.waitFor(
          () => first.editor!.pages.length == 1,
          'Page deletion was not delivered after restart',
        );
        expect(first.editor!.canUndo, isFalse);
        expect(first.editor!.canRedo, isFalse);
        for (final peer in [first, second]) {
          expect(
            await peer.runtime.store.isTombstoned(
              notebook.uid,
              'page',
              deletedPageId,
            ),
            isTrue,
          );
          final scoped = await peer.database
              .customSelect(
                'SELECT asset_id FROM asset_references '
                'WHERE document_id = ?',
                variables: [Variable<String>(notebook.uid)],
              )
              .get();
          expect(scoped, isEmpty);
        }
        for (var cycle = 0; cycle < 2; cycle++) {
          await first.restartSync();
          second.editor!.undo();
          await second.flush();
          await second.sync();
          await first.waitFor(
            () => _hasMedia(first),
            'Undo did not restore the page and media',
          );
          expect(second.editor!.pages.last.id, isNot(deletedPageId));
          await _expectMedia(first);
          await _expectMedia(second);
          expect(
            first.editor!.pages.last.textBlocks.map((b) => b.id).toSet(),
            second.editor!.pages.last.textBlocks.map((b) => b.id).toSet(),
          );
          if (cycle == 0) {
            await first.restartSync();
            second.editor!.redo();
            await second.flush();
            await second.sync();
            await first.waitFor(
              () => first.editor!.pages.length == 1,
              'Redo did not delete the restored page',
            );
          }
        }
        final snapshot =
            (await first.api.get(
                  '/v2/documents/${notebook.uid}/snapshot',
                )).decodeJson()
                as Map;
        final serverPages = (snapshot['state'] as Map)['pages'] as Map;
        expect(
          serverPages.keys.toSet(),
          first.editor!.pages.map((page) => page.id).toSet(),
        );
        expect(first.editor!.pages.first.inkStrokes.single.id, strokeId);
        expect(second.editor!.pages.first.inkStrokes.single.id, strokeId);
        expect(
          await first.runtime.store.pending(includeDeferred: true),
          isEmpty,
        );
        expect(
          await second.runtime.store.pending(includeDeferred: true),
          isEmpty,
        );
      });
    },
    skip: _baseUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
