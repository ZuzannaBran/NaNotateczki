import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_history_checkpoint.dart';
import 'package:program/data/sync/editor_history_notebook_codec.dart';
import 'package:program/data/sync/editor_history_store.dart';
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
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/text_block.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw const SocketException('Offline');
  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw const SocketException('Offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  late NotesDatabase database;
  late NotebookRepository repository;
  late SyncEngine engine;
  late EditorV2OperationWriter writer;
  late EditorHistoryNotebookCodec codec;
  late Notebook fixture;

  void open() {
    database = NotesDatabase(NativeDatabase(file));
    repository = NotebookRepository(database);
    final projector = EditorSqliteProjector(
      database,
      verifiedAssetBuffer: VerifiedEditorAssetBuffer(),
    );
    engine = SyncEngine(
      store: OperationStore(database),
      gateway: _OfflineGateway(),
      actorId: 'history-codec-test',
      checkpointScope: 'history-codec-test',
      enableRealtime: false,
      applyRemote: (op, _) => projector.apply(op),
    );
    writer = EditorV2OperationWriter(syncEngine: engine, projector: projector);
    codec = EditorHistoryNotebookCodec(projector);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nn-history-codec-');
    file = File('${directory.path}/notes.sqlite');
    open();
    await repository.enableAccountOperations(writer);
    final original = await repository.createNotebook(title: 'History fixture');
    final png = Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      ...List.filled(200000, 7),
    ]);
    final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nhistory'));
    final imageAsset = writer.stageQuillAsset(
      documentId: original.uid,
      bytes: png,
      embedType: 'image',
    );
    final pdfAsset = writer.stageQuillAsset(
      documentId: original.uid,
      bytes: pdf,
      embedType: 'pdf',
    );
    final delta = jsonEncode([
      {
        'insert': 'Title ',
        'attributes': {'bold': true, 'color': '#123456'},
      },
      {
        'insert': {'image': 'asset:${imageAsset.assetId}'},
      },
      {
        'insert': {'pdf': 'asset:${pdfAsset.assetId}'},
      },
      {'insert': '\n'},
    ]);
    final changed = original.copyWith(
      pages: [
        original.pages.single.copyWith(
          isBookmarked: true,
          imageBlocks: [
            ImageBlock(
              id: 'png',
              path: '',
              ocrText: '',
              bytes: png,
              imageMime: 'image/png',
              imageExt: 'png',
              position: const Offset(10, 20),
              width: 80,
              height: 50,
              rotation: 0.25,
              cropLeft: 0.1,
              cropTop: 0.2,
              cropRight: 0.9,
              cropBottom: 0.8,
            ),
            ImageBlock(
              id: 'pdf',
              path: '',
              ocrText: '',
              bytes: pdf,
              imageMime: 'application/pdf',
              imageExt: 'pdf',
              position: const Offset(30, 40),
              width: 60,
              height: 90,
            ),
          ],
          textBlocks: [
            TextBlock(
              id: 'quill',
              text: 'Title \uFFFC\uFFFC',
              deltaJson: delta,
              position: const Offset(3, 4),
              fontSize: 19,
              color: const Color(0xFF123456),
              width: 150,
              rotation: 0.5,
            ),
          ],
          inkStrokes: [
            InkStroke(
              id: 'stroke',
              points: [const InkPoint(dx: 1, dy: 2, pressure: 0.5)],
              color: const Color(0x80123456),
              width: 3,
              tool: DrawingTool.highlighter,
            ),
          ],
        ),
      ],
    );
    await writer.writeNotebookChange(before: original, after: changed);
    fixture = (await repository.getNotebook(original.uid))!;
  });
  tearDown(() async {
    await engine.stop();
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'metadata and verified media round trip after reopening SQLite',
    () async {
      final encoded = await codec.encode(fixture);
      final json = jsonEncode(encoded);
      expect(json.length, lessThan(10000));
      expect(json, isNot(contains('base64')));
      expect(
        (encoded['pages'] as List).single['images'].first,
        isNot(contains('path')),
      );
      await engine.stop();
      await database.close();
      open();
      final restored = await codec.decode(
        jsonDecode(json) as Map<String, dynamic>,
        documentId: fixture.uid,
      );
      expect(await codec.encode(restored), encoded);
      expect(restored.title, fixture.title);
      expect(restored.createdAt.isAtSameMomentAs(fixture.createdAt), isTrue);
      expect(restored.createdAt.isUtc, isTrue);
      final page = restored.pages.single;
      expect(page.isBookmarked, isTrue);
      expect(
        page.textBlocks.single.deltaJson,
        fixture.pages.single.textBlocks.single.deltaJson,
      );
      expect(page.textBlocks.single.rotation, 0.5);
      expect(page.inkStrokes.single.color, const Color(0x80123456));
      expect(page.inkStrokes.single.tool, DrawingTool.highlighter);
      expect(
        page.imageBlocks.first.bytes,
        fixture.pages.single.imageBlocks.first.bytes,
      );
      expect(page.imageBlocks.first.cropLeft, 0.1);
      expect(page.imageBlocks.first.cropBottom, 0.8);
      expect(page.imageBlocks.first.rotation, 0.25);
      expect(page.imageBlocks.last.imageMime, 'application/pdf');
      expect(
        page.imageBlocks.map((image) => image.path),
        everyElement(isEmpty),
      );
    },
  );

  test(
    'deleted media are recoverable without restoring document rows or outbox',
    () async {
      final encoded = await codec.encode(fixture);
      final bare = fixture.copyWith(
        pages: [fixture.pages.single.copyWith(imageBlocks: [], textBlocks: [])],
      );
      await writer.writeNotebookChange(before: fixture, after: bare);
      final before = (await engine.store.pending())
          .map((op) => op.operationId)
          .toList();
      expect(
        await database.customSelect('SELECT * FROM asset_references').get(),
        isEmpty,
      );
      final restored = await codec.decode(encoded, documentId: fixture.uid);
      expect(restored.pages.single.imageBlocks, hasLength(2));
      expect(
        restored.pages.single.textBlocks.single.text,
        'Title \uFFFC\uFFFC',
      );
      expect(
        (await repository.getNotebook(fixture.uid))!.pages.single.imageBlocks,
        isEmpty,
      );
      expect(
        (await engine.store.pending()).map((op) => op.operationId),
        before,
      );
    },
  );

  test(
    'another document cannot encode or decode receipts from this history',
    () async {
      final encoded = await codec.encode(fixture);
      final foreign = await repository.createNotebook();
      final renamed = fixture.copyWith(uid: foreign.uid);
      await expectLater(codec.encode(renamed), throwsFormatException);
      await expectLater(
        codec.decode(encoded, documentId: foreign.uid),
        throwsFormatException,
      );
      final forged = jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
      forged['uid'] = foreign.uid;
      await expectLater(
        codec.decode(forged, documentId: foreign.uid),
        throwsFormatException,
      );
    },
  );

  test(
    'untrusted paths and uncommitted bytes are not history media sources',
    () async {
      final image = fixture.pages.single.imageBlocks.first;
      for (final invalid in [
        image.copyWith(path: '/does-not-exist/secret.png', clearBytes: true),
        image.copyWith(
          bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 8]),
        ),
        image.copyWith(imageMime: 'application/pdf'),
      ]) {
        final changed = fixture.copyWith(
          pages: [
            fixture.pages.single.copyWith(imageBlocks: [invalid]),
          ],
        );
        await expectLater(codec.encode(changed), throwsFormatException);
      }
    },
  );

  test(
    'missing and corrupt durable BLOBs fail closed without changing the journal',
    () async {
      final encoded = await codec.encode(fixture);
      final before = (await engine.store.pending())
          .map((op) => op.operationId)
          .toList();
      await database.customStatement(
        'UPDATE operation_asset_bytes SET bytes = ?',
        [
          Uint8List.fromList([1, 2, 3]),
        ],
      );
      await expectLater(
        codec.decode(encoded, documentId: fixture.uid),
        throwsFormatException,
      );
      await expectLater(codec.encode(fixture), throwsFormatException);
      await database.customStatement('DELETE FROM operation_asset_bytes');
      await expectLater(
        codec.decode(encoded, documentId: fixture.uid),
        throwsFormatException,
      );
      expect(
        (await engine.store.pending()).map((op) => op.operationId),
        before,
      );
      expect(
        (await repository.getNotebook(fixture.uid))!.pages.single.imageBlocks,
        hasLength(2),
      );
    },
  );

  test(
    'receipt tampering, extra fields and unused assets are refused',
    () async {
      final encoded = await codec.encode(fixture);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (root) => root['version'] = 1.0,
        (root) => root['version'] = 2,
        (root) => root['kind'] = 'planner',
        (root) => root['path'] = '/tmp/forged',
        (root) =>
            ((root['assets'] as Map).values.first as Map)['sha256'] = '0' * 64,
        (root) =>
            ((root['pages'] as List).single['images'].first as Map)['bytes'] = [
              1,
              2,
            ],
        (root) {
          final page = (root['pages'] as List).single as Map;
          (page['images'] as List).clear();
          (page['texts'] as List).clear();
        },
        (root) => root['createdAt'] = 'not-a-date',
        (root) => root['createdAt'] = '2026-02-31T00:00:00.000Z',
        (root) => (root['pages'] as List).clear(),
      ]) {
        final copy = jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
        mutate(copy);
        await expectLater(
          codec.decode(copy, documentId: fixture.uid),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'conflicting durable receipts cannot select arbitrary asset bytes',
    () async {
      final encoded = await codec.encode(fixture);
      final rows = await database
          .customSelect(
            "SELECT operation_id, envelope_json FROM operations WHERE kind = 'asset.attach'",
          )
          .get();
      final first = jsonDecode(rows.first.read<String>('envelope_json')) as Map;
      final target = rows.firstWhere((row) {
        final value = jsonDecode(row.read<String>('envelope_json')) as Map;
        return value['payload']['sha256'] != first['payload']['sha256'];
      });
      final changed = jsonDecode(target.read<String>('envelope_json')) as Map;
      changed['payload']['assetId'] = first['payload']['assetId'];
      await database.customStatement(
        'UPDATE operations SET envelope_json = ? WHERE operation_id = ?',
        [jsonEncode(changed), target.read<String>('operation_id')],
      );
      await expectLater(
        codec.decode(encoded, documentId: fixture.uid),
        throwsFormatException,
      );
      await expectLater(codec.encode(fixture), throwsFormatException);
    },
  );

  test(
    'plain text, page order and layer order round trip without Delta synthesis',
    () async {
      final original = fixture.pages.single;
      final plain = original.copyWith(
        textBlocks: [
          for (var index = 0; index < 2; index++)
            TextBlock(
              id: 'plain-$index',
              text: 'Plain $index 😀',
              position: Offset(4.0 + index, 5),
              fontSize: 21,
              color: const Color(0xFF102030),
              width: 120,
            ),
        ],
      );
      final extra = original.copyWith(
        id: 'other-page',
        title: 'Earlier',
        textBlocks: [],
        imageBlocks: [],
        inkStrokes: [],
      );
      final source = fixture.copyWith(pages: [extra, plain]);
      final value = await codec.encode(source);
      final restored = await codec.decode(value, documentId: fixture.uid);
      expect(restored.pages.map((page) => page.id), [
        'other-page',
        original.id,
      ]);
      expect(restored.pages.last.textBlocks.map((text) => text.id), [
        'plain-0',
        'plain-1',
      ]);
      expect(
        restored.pages.last.textBlocks.map((text) => text.deltaJson),
        everyElement(isNull),
      );
      expect(restored.pages.last.textBlocks.last.text, 'Plain 1 😀');
      expect(restored.pages.last.imageBlocks.map((image) => image.id), [
        'png',
        'pdf',
      ]);
    },
  );

  test(
    'later identical imports cannot change an older boundary asset alias',
    () async {
      final encoded = await codec.encode(fixture);
      final image = fixture.pages.single.imageBlocks.first;
      final id = (encoded['pages'] as List).single['images'].first['assetId'];
      final receipt = (encoded['assets'] as Map)[id] as Map;
      final alias = VerifiedEditorAsset(
        assetId: '000-alias',
        sha256: receipt['sha256'] as String,
        sizeBytes: receipt['sizeBytes'] as int,
        mediaType: receipt['mediaType'] as String,
      );
      writer.projector.verifiedAssetBuffer!.stage(
        receipt: alias.attachPayload,
        bytes: image.bytes!,
      );
      writer.registerVerifiedAsset(
        documentId: fixture.uid,
        objectId: 'alias-image',
        asset: alias,
      );
      final extended = fixture.copyWith(
        pages: [
          fixture.pages.single.copyWith(
            imageBlocks: [
              ...fixture.pages.single.imageBlocks,
              image.copyWith(id: 'alias-image'),
            ],
          ),
        ],
      );
      await writer.writeNotebookChange(before: fixture, after: extended);
      expect(await codec.encode(fixture), encoded);
    },
  );

  test(
    'duplicate identities and invalid geometry cannot be recovered',
    () async {
      final encoded = await codec.encode(fixture);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (page) => (page['images'].first as Map)['id'] = 'stroke',
        (page) => (page['images'].first as Map)['width'] = 0,
        (page) => (page['images'].first as Map)['cropLeft'] = 0.95,
        (page) => (page['texts'].single as Map)['color'] = -1,
        (page) => (page['texts'].single as Map)['fontSize'] = double.nan,
        (page) =>
            (page['ink'].single as Map)['tool'] = DrawingTool.eraserArea.index,
        (page) => (page['ink'].single as Map)['points'] = [],
      ]) {
        final copy = jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
        mutate((copy['pages'] as List).single as Map<String, dynamic>);
        await expectLater(
          codec.decode(copy, documentId: fixture.uid),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'Quill text mismatch, URL embeds and media type mismatch are refused',
    () async {
      final encoded = await codec.encode(fixture);
      for (final mutate in <void Function(Map)>[
        (text) => text['text'] = 'different text',
        (text) => text['deltaJson'] = jsonEncode([
          {
            'insert': {'image': 'https://example.test/image.png'},
          },
          {'insert': '\n'},
        ]),
        (text) {
          final delta = jsonDecode(text['deltaJson'] as String) as List;
          final embed = (delta[1] as Map)['insert'] as Map;
          embed['pdf'] = embed.remove('image');
          text['deltaJson'] = jsonEncode(delta);
        },
      ]) {
        final copy = jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
        mutate((copy['pages'] as List).single['texts'].single as Map);
        await expectLater(
          codec.decode(copy, documentId: fixture.uid),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'large metadata is bounded while large media stays outside JSON',
    () async {
      final encoded = await codec.encode(fixture);
      final copy = Map<String, dynamic>.from(encoded)
        ..['title'] = 'x' * EditorHistoryCheckpoint.maximumBytes;
      await expectLater(
        codec.decode(copy, documentId: fixture.uid),
        throwsFormatException,
      );
      await expectLater(
        codec.encode(fixture.copyWith(title: copy['title'] as String)),
        throwsFormatException,
      );
      expect(jsonEncode(encoded).length, lessThan(10000));
    },
  );

  test(
    'metadata and byte fingerprints freeze before asynchronous I/O',
    () async {
      final sourcePage = fixture.pages.single;
      final bytes = Uint8List.fromList(sourcePage.imageBlocks.first.bytes!);
      final points = List<InkPoint>.of(sourcePage.inkStrokes.single.points);
      final pages = [
        sourcePage.copyWith(
          imageBlocks: [sourcePage.imageBlocks.first.copyWith(bytes: bytes)],
          inkStrokes: [sourcePage.inkStrokes.single.copyWith(points: points)],
        ),
      ];
      final source = fixture.copyWith(pages: pages);
      final expected = await codec.encode(source);
      final pending = codec.encode(source);
      bytes[0] = 0;
      points.clear();
      pages.clear();
      expect(await pending, expected);
    },
  );

  test('recovery input is frozen before checking durable receipts', () async {
    final value = await codec.encode(fixture);
    final pending = codec.decode(value, documentId: fixture.uid);
    ((value['assets'] as Map).values.first as Map)['sha256'] = '0' * 64;
    (value['pages'] as List).clear();
    final restored = await pending;
    expect(restored.pages.single.imageBlocks, hasLength(2));
    expect(restored.pages.single.imageBlocks.first.bytes![0], 137);
  });

  test(
    'atomic media history survives delete, restart and a new inverse',
    () async {
      final before = await codec.encode(fixture);
      final bare = fixture.copyWith(
        pages: [
          fixture.pages.single.copyWith(
            textBlocks: [],
            imageBlocks: [],
            inkStrokes: [],
          ),
        ],
      );
      late EditorHistoryCheckpoint saved;
      final deleted = await writer.writeNotebookChange(
        before: fixture,
        after: bare,
        onCommittedInTransaction: (operations) async {
          saved = EditorHistoryCheckpoint(
            documentId: fixture.uid,
            ownerId: operations.last.actorId,
            headOperationId: operations.last.operationId,
            undo: [
              StoredEditorGesture(
                before: before,
                after: await codec.encode(bare),
                operationId: operations.last.operationId,
              ),
            ],
            redo: [],
          );
          await EditorHistoryStore(engine.store).save(saved);
        },
      );
      await engine.stop();
      await database.close();
      open();
      final history = (await EditorHistoryStore(
        engine.store,
      ).load(documentId: fixture.uid, ownerId: saved.ownerId))!;
      final boundary = await codec.decode(
        history.undo.single.before,
        documentId: fixture.uid,
      );
      final current = (await repository.getNotebook(fixture.uid))!;
      expect(current.pages.single.imageBlocks, isEmpty);
      final page = boundary.pages.single;
      final recreated = boundary.copyWith(
        pages: [
          page.copyWith(
            imageBlocks: [
              for (final image in page.imageBlocks)
                image.copyWith(id: 'restored-${image.id}'),
            ],
            textBlocks: [
              for (final text in page.textBlocks)
                text.copyWith(id: 'restored-${text.id}'),
            ],
            inkStrokes: [
              for (final stroke in page.inkStrokes)
                stroke.copyWith(id: 'restored-${stroke.id}'),
            ],
          ),
        ],
      );
      final inverse = await writer.writeNotebookChange(
        before: current,
        after: recreated,
        revertsOperationId: deleted.last.operationId,
        onCommittedInTransaction: (operations) async {
          await EditorHistoryStore(engine.store).save(
            EditorHistoryCheckpoint(
              documentId: fixture.uid,
              ownerId: operations.last.actorId,
              headOperationId: operations.last.operationId,
              undo: [],
              redo: [
                StoredEditorGesture(
                  before: await codec.encode(current),
                  after: await codec.encode(recreated),
                  operationId: operations.last.operationId,
                ),
              ],
            ),
          );
        },
      );
      expect(inverse, isNotEmpty);
      expect(
        inverse.every(
          (op) => op.revertsOperationId == deleted.last.operationId,
        ),
        isTrue,
      );
      expect(inverse.first.actorSeq, deleted.last.actorSeq + 1);
      for (final id in ['png', 'pdf', 'quill', 'stroke']) {
        expect(
          await engine.store.isTombstoned(
            fixture.uid,
            'object',
            id,
            pageId: fixture.pages.single.id,
          ),
          isTrue,
        );
      }
      final restored = (await repository.getNotebook(fixture.uid))!;
      expect(restored.pages.single.imageBlocks.map((image) => image.id), [
        'restored-png',
        'restored-pdf',
      ]);
      expect(
        restored.pages.single.imageBlocks.first.bytes,
        fixture.pages.single.imageBlocks.first.bytes,
      );
      expect(
        restored.pages.single.textBlocks.single.deltaJson,
        fixture.pages.single.textBlocks.single.deltaJson,
      );
      await engine.stop();
      await database.close();
      open();
      final redo = (await EditorHistoryStore(
        engine.store,
      ).load(documentId: fixture.uid, ownerId: saved.ownerId))!;
      expect(redo.undo, isEmpty);
      expect(redo.redo.single.operationId, inverse.last.operationId);
      final recovered = await codec.decode(
        redo.redo.single.after,
        documentId: fixture.uid,
      );
      expect(recovered.pages.single.imageBlocks.map((image) => image.id), [
        'restored-png',
        'restored-pdf',
      ]);
    },
  );

  test(
    'board metadata and immutable recovered image copies are preserved',
    () async {
      final board = await repository.createBoard();
      final encodedBoard = await codec.encode(board);
      final decodedBoard = await codec.decode(
        encodedBoard,
        documentId: board.uid,
      );
      expect(decodedBoard.kind, NotebookKind.board);
      expect(decodedBoard.pages.single.id, board.pages.single.id);
      final encoded = await codec.encode(fixture);
      final first = await codec.decode(encoded, documentId: fixture.uid);
      first.pages.single.imageBlocks.first.bytes![0] = 0;
      final second = await codec.decode(encoded, documentId: fixture.uid);
      expect(second.kind, NotebookKind.notebook);
      expect(second.pages.single.imageBlocks.first.bytes![0], 137);
      expect(await codec.encode(second), encoded);
    },
  );
}
