import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
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
