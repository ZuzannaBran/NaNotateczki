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
import 'package:program/features/editor/state/editor_operation_bridge.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/text_block.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async {
    throw StateError('Test is intentionally offline.');
  }

  @override
  Future<OperationFeedPage> readAfter(int cursor) async {
    throw StateError('Test is intentionally offline.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NotesDatabase database;
  late NotebookRepository repository;
  late OperationStore store;
  late SyncEngine engine;
  late EditorV2OperationWriter writer;

  setUp(() async {
    database = NotesDatabase(NativeDatabase.memory());
    repository = NotebookRepository(database);
    store = OperationStore(database);
    final projector = EditorSqliteProjector(database);
    engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'local',
      checkpointScope: 'test-account',
      enableRealtime: false,
      applyRemote: (operation, pending) => projector.apply(operation),
    );
    writer = EditorV2OperationWriter(
      syncEngine: engine,
      projector: projector,
    );
  });

  tearDown(() async {
    await engine.stop();
    await database.close();
  });

  test('one complete stroke creates one durable operation, no snapshot',
      () async {
    final notebook = await repository.createNotebook();
    final before = notebook.pages.single;
    final stroke = InkStroke(
      id: 'v2-stroke-one',
      color: const Color(0xFF112233),
      width: 2,
      tool: DrawingTool.pen,
      points: [const InkPoint(dx: 2, dy: 4, pressure: 0.5)],
    );
    final after = before.copyWith(inkStrokes: [stroke]);

    final committed = await writer.writePageChange(
      documentId: notebook.uid,
      before: before,
      after: after,
    );
    expect(committed, hasLength(1));
    expect(committed.single.kind, OperationKind.strokeCreate);
    expect((await store.pending()).single.operationId,
        committed.single.operationId);
    expect(
      (await repository.getNotebook(notebook.uid))
          ?.pages.single.inkStrokes.single.id,
      stroke.id,
    );

    expect(
      await writer.writePageChange(
        documentId: notebook.uid,
        before: after,
        after: after,
      ),
      isEmpty,
    );
    expect(await store.pending(), hasLength(1));

    final deleted = await writer.writePageChange(
      documentId: notebook.uid,
      before: after,
      after: before,
    );
    expect(deleted.single.kind, OperationKind.objectDelete);
    expect(
      (await repository.getNotebook(notebook.uid))
          ?.pages.single.inkStrokes,
      isEmpty,
    );
    await expectLater(
      writer.writePageChange(
        documentId: notebook.uid,
        before: before,
        after: after,
      ),
      throwsStateError,
    );
  });

  test('multiple page edits commit as one causally ordered batch',
      () async {
    final notebook = await repository.createNotebook();
    final first = notebook.pages.single;
    final newPage = first.copyWith(
      id: 'second-page',
      title: 'Second page',
      inkStrokes: const [],
    );
    final stroke = InkStroke(
      id: 'v2-ink-two',
      color: const Color(0xFF112233),
      width: 2,
      tool: DrawingTool.pen,
      points: [const InkPoint(dx: 5, dy: 6, pressure: 0.5)],
    );
    final after = notebook.copyWith(
      pages: [
        first.copyWith(inkStrokes: [stroke]),
        newPage,
      ],
    );
    final ops = await writer.writeNotebookChange(
      before: notebook,
      after: after,
    );
    expect(ops.map((operation) => operation.kind), [
      OperationKind.strokeCreate,
      OperationKind.pageCreate,
    ]);
    expect(ops[1].dependencies, contains(ops[0].operationId));
    final saved = (await repository.getNotebook(notebook.uid))!;
    expect(saved.pages, hasLength(2));
    expect(saved.pages.first.inkStrokes.single.id, stroke.id);
    expect(saved.pages.last.id, newPage.id);
    expect(await store.pending(), hasLength(2));
  });

  test('multi-page transaction rolls back earlier edits on identity error',
      () async {
    final notebook = await repository.createNotebook();
    final other = await repository.createNotebook();
    final old = notebook.pages.single;
    final changed = notebook.copyWith(
      pages: [
        old.copyWith(
          inkStrokes: [
            InkStroke(
              id: 'rollback-stroke',
              color: const Color(0xFF223344),
              width: 2,
              tool: DrawingTool.pen,
              points: [
                const InkPoint(dx: 2, dy: 4, pressure: 0.6),
              ],
            ),
          ],
        ),
        other.pages.single,
      ],
    );
    await expectLater(
      writer.writeNotebookChange(
        before: notebook,
        after: changed,
      ),
      throwsStateError,
    );
    final current = await repository.getNotebook(notebook.uid);
    expect(current?.pages, hasLength(1));
    expect(current?.pages.single.inkStrokes, isEmpty);
    expect(await store.pending(), isEmpty);
  });

  test('cross-page ink move preserves one ID and both page orders',
      () async {
    final notebook = await repository.createNotebook();
    final firstPage = notebook.pages.single;
    final secondPage = firstPage.copyWith(
      id: 'ink-destination',
      title: 'Destination',
      inkStrokes: [],
      textBlocks: [],
      imageBlocks: [],
    );
    InkStroke stroke(String id) => InkStroke(
      id: id,
      color: const Color(0xFF223344),
      width: 1.5,
      tool: DrawingTool.pen,
      points: [const InkPoint(dx: 1.0, dy: 2.0, pressure: 0.6)],
    );
    final a = stroke('ink-a');
    final b = stroke('ink-b');
    final c = stroke('ink-c');
    final starting = notebook.copyWith(pages: [
      firstPage.copyWith(inkStrokes: [a, b]),
      secondPage.copyWith(inkStrokes: [c]),
    ]);
    await writer.writeNotebookChange(before: notebook, after: starting);
    final moved = notebook.copyWith(pages: [
      firstPage.copyWith(inkStrokes: [b]),
      secondPage.copyWith(inkStrokes: [c, a]),
    ]);
    final operations = await writer.writeNotebookChange(
      before: starting,
      after: moved,
    );
    expect(
      operations.where((op) => op.kind == OperationKind.objectMove),
      hasLength(1),
    );
    expect(
      operations.where((op) => op.kind == OperationKind.objectDelete),
      isEmpty,
    );
    expect(
      operations.where((op) => op.kind == OperationKind.strokeCreate),
      isEmpty,
    );
    final saved = (await repository.getNotebook(notebook.uid))!;
    expect(
      saved.pages.first.inkStrokes.map((s) => s.id).toList(),
      ['ink-b'],
    );
    expect(
      saved.pages.last.inkStrokes.map((s) => s.id).toList(),
      ['ink-c', 'ink-a'],
    );
    expect(
      await store.isTombstoned(
        notebook.uid,
        'object',
        'ink-a',
        pageId: firstPage.id,
      ),
      isFalse,
    );
    expect(
      await store.isTombstoned(
        notebook.uid,
        'object',
        'ink-a',
        pageId: secondPage.id,
      ),
      isFalse,
    );

    final modified = b.copyWith(width: 3);
    final invalid = notebook.copyWith(pages: [
      firstPage.copyWith(inkStrokes: [a]),
      secondPage.copyWith(inkStrokes: [c, modified]),
    ]);
    await expectLater(
      writer.writeNotebookChange(before: starting, after: invalid),
      throwsUnsupportedError,
    );
  });

  test('image creation stores authenticated bytes in the same v2 batch',
      () async {
    final buffer = VerifiedEditorAssetBuffer();
    final bufferedProjector = EditorSqliteProjector(
      database,
      verifiedAssetBuffer: buffer,
    );
    final bufferedEngine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'image-create-actor',
      checkpointScope: 'image-create-checkpoint',
      enableRealtime: false,
      applyRemote: (operation, pending) => bufferedProjector.apply(operation),
    );
    addTearDown(bufferedEngine.stop);
    final bufferedWriter = EditorV2OperationWriter(
      syncEngine: bufferedEngine,
      projector: bufferedProjector,
    );
    final rawBytes = Uint8List.fromList([137, 80, 78, 71, 0, 1]);
    final digest = crypto.sha256.convert(rawBytes).toString();
    final receipt = <String, dynamic>{
      'assetId': 'image-verified',
      'sha256': digest,
      'sizeBytes': rawBytes.length,
      'mediaType': 'image/png',
    };
    final notebook = await repository.createNotebook();
    final before = notebook.pages.first;
    final image = ImageBlock(
      id: 'image-object',
      path: '',
      ocrText: '',
      bytes: rawBytes,
      imageExt: 'png',
      imageMime: 'image/png',
      position: const Offset(4, 5),
      width: 160,
      height: 120,
    );
    final after = before.copyWith(imageBlocks: [image]);
    final verified = VerifiedEditorAsset(
      assetId: 'image-verified',
      sha256: digest,
      sizeBytes: rawBytes.length,
      mediaType: 'image/png',
    );
    await expectLater(
      bufferedWriter.writePageChange(
        documentId: notebook.uid,
        before: before,
        after: after,
        verifiedAssets: {'image-object': verified},
      ),
      throwsStateError,
    );
    expect(await store.pending(), isEmpty);
    expect(
      (await repository.getNotebook(notebook.uid))!.pages.first.imageBlocks,
      isEmpty,
    );

    buffer.stage(receipt: receipt, bytes: rawBytes);
    final committed = await bufferedWriter.writePageChange(
      documentId: notebook.uid,
      before: before,
      after: after,
      verifiedAssets: {'image-object': verified},
    );
    expect(committed.map((op) => op.kind), [
      OperationKind.objectCreate,
      OperationKind.assetAttach,
    ]);
    final saved = (await repository.getNotebook(notebook.uid))!
        .pages.first.imageBlocks.single;
    expect(saved.id, image.id);
    expect(saved.bytes, orderedEquals(rawBytes));
    expect(saved.position.dx, 4);
    final references = await database.customSelect(
      'SELECT storage_path, checksum_sha256, byte_length '
      'FROM asset_references WHERE document_id = ? AND asset_id = ?',
      variables: [
        Variable<String>(notebook.uid),
        const Variable<String>('image-verified'),
      ],
    ).get();
    expect(references, hasLength(1));
    expect(references.single.read<String>('checksum_sha256'), digest);
    expect(references.single.read<int>('byte_length'), rawBytes.length);
    expect(
      references.single.read<String>('storage_path'),
      'sqlite-blob:$digest',
    );
    buffer.clear();
    expect(
      (await repository.getNotebook(notebook.uid))!
          .pages.first.imageBlocks.single.bytes,
      orderedEquals(rawBytes),
    );
  });

  test('image move preserves the asset and never recreates its ID',
      () async {
    final notebook = await repository.createNotebook();
    final page = notebook.pages.single;
    final second = page.copyWith(
      id: 'image-destination',
      title: 'Media',
      inkStrokes: [],
      textBlocks: [],
      imageBlocks: [],
    );
    final image = ImageBlock(
      id: 'verified-image',
      path: '',
      ocrText: '',
      bytes: Uint8List.fromList([137, 80, 78, 71]),
      imageExt: 'png',
      imageMime: 'image/png',
      position: const Offset(10, 20),
      width: 120,
      height: 80,
    );
    final initial = notebook.copyWith(pages: [
      page.copyWith(imageBlocks: [image]),
      second,
    ]);
    expect(await repository.saveNotebook(initial), isTrue);
    await store.attachAssetReference(
      documentId: notebook.uid,
      pageId: page.id,
      objectId: image.id,
      assetId: 'asset-verified',
      storagePath: 'assets/asset-verified',
      checksumSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      byteLength: 4,
    );
    final persisted = (await repository.getNotebook(notebook.uid))!;
    final relocated = persisted.copyWith(pages: [
      persisted.pages.first.copyWith(imageBlocks: []),
      persisted.pages.last.copyWith(
        imageBlocks: [
          persisted.pages.first.imageBlocks.single.copyWith(
            position: const Offset(60, 90),
          ),
        ],
      ),
    ]);
    final written = await writer.writeNotebookChange(
      before: persisted,
      after: relocated,
    );
    expect(
      written.where((op) => op.kind == OperationKind.objectMove),
      hasLength(1),
    );
    expect(
      written.where((op) => op.kind == OperationKind.objectCreate),
      isEmpty,
    );
    expect(
      written.where((op) => op.kind == OperationKind.objectDelete),
      isEmpty,
    );
    final saved = (await repository.getNotebook(notebook.uid))!;
    expect(saved.pages.first.imageBlocks, isEmpty);
    expect(saved.pages.last.imageBlocks.single.id, image.id);
    expect(saved.pages.last.imageBlocks.single.position.dx, 60);
    expect(
      saved.pages.last.imageBlocks.single.bytes,
      orderedEquals(image.bytes!),
    );
    final refs = await database.customSelect(
      'SELECT object_id FROM asset_references WHERE asset_id = ?',
      variables: [const Variable<String>('asset-verified')],
    ).get();
    expect(refs, hasLength(1));
    expect(
      refs.single.read<String>('object_id'),
      'page:["image-destination","verified-image"]',
    );

    final removed = relocated.copyWith(pages: [
      relocated.pages.first,
      relocated.pages.last.copyWith(imageBlocks: []),
    ]);
    await expectLater(
      writer.writeNotebookChange(before: relocated, after: removed),
      throwsUnsupportedError,
    );
    expect(
      (await repository.getNotebook(notebook.uid))!
          .pages.last.imageBlocks.single.id,
      image.id,
    );
  });

  test('Quill update reuses SQLite atom identity after each commit',
      () async {
    final notebook = await repository.createNotebook();
    final before = notebook.pages.single;
    TextBlock block(String text) => TextBlock(
      id: 'text-one',
      text: text,
      deltaJson: '[{"insert":"$text\\n"}]',
      position: const Offset(3, 4),
      fontSize: 18,
      color: const Color(0xFF223344),
      width: 180,
    );

    final first = before.copyWith(textBlocks: [block('A')]);
    final create = await writer.writePageChange(
      documentId: notebook.uid,
      before: before,
      after: first,
    );
    expect(create.map((op) => op.kind), [
      OperationKind.objectCreate,
      OperationKind.textInsert,
    ]);
    final second = before.copyWith(textBlocks: [block('B')]);
    final changed = await writer.writePageChange(
      documentId: notebook.uid,
      before: first,
      after: second,
    );
    expect(changed.map((op) => op.kind), [
      OperationKind.textDelete,
      OperationKind.textInsert,
    ]);
    expect(
      (await repository.getNotebook(notebook.uid))
          ?.pages.single.textBlocks.single.text,
      'B',
    );
    final atoms = await store.textAtoms(
      documentId: notebook.uid,
      pageId: before.id,
      objectId: 'text-one',
    );
    expect(atoms.length, 3);
  });

  test('stale Quill formatting cannot overwrite the durable text',
      () async {
    final notebook = await repository.createNotebook();
    final page = notebook.pages.single;
    TextBlock block(String text, String delta) => TextBlock(
      id: 'rich-text',
      text: text,
      deltaJson: delta,
      position: Offset.zero,
      fontSize: 18,
      color: const Color(0xFF111111),
      width: 200,
    );
    final saved = page.copyWith(textBlocks: [
      block('A', r'[{"insert":"A\n"}]'),
    ]);
    await writer.writePageChange(
      documentId: notebook.uid,
      before: page,
      after: saved,
    );
    final existing = await store.pending();
    final stale = page.copyWith(textBlocks: [
      block('A', r'[{"insert":"A","attributes":{"bold":true}},'
          r'{"insert":"\n"}]'),
    ]);
    final edited = page.copyWith(textBlocks: [
      block('B', r'[{"insert":"B\n"}]'),
    ]);
    await expectLater(
      writer.writePageChange(
        documentId: notebook.uid,
        before: stale,
        after: edited,
      ),
      throwsStateError,
    );
    expect(await store.pending(), hasLength(existing.length));
    expect(
      (await repository.getNotebook(notebook.uid))
          ?.pages.single.textBlocks.single.text,
      'A',
    );
  });

  test('a failed media edit never writes an outbox operation', () async {
    final notebook = await repository.createNotebook();
    final page = notebook.pages.single;
    final changed = page.copyWith(
      inkStrokes: [
        InkStroke(
          id: 'stroke-one',
          color: const Color(0xFF010203),
          width: 1.5,
          tool: DrawingTool.pen,
          points: [const InkPoint(dx: 1, dy: 2, pressure: 0.4)],
        ),
      ],
      textBlocks: [
        TextBlock(
          id: 'rich',
          text: '\uFFFC',
          deltaJson: r'[{"insert":{"image":"asset:unverified"}}]',
          position: Offset.zero,
          fontSize: 18,
          color: const Color(0xFF111111),
          width: 200,
        ),
      ],
    );
    await expectLater(
      writer.writePageChange(
        documentId: notebook.uid,
        before: page,
        after: changed,
      ),
      throwsStateError,
    );
    expect(await store.pending(), isEmpty);
    expect(
      (await repository.getNotebook(notebook.uid))
          ?.pages.single.inkStrokes,
      isEmpty,
    );
  });
}
