import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'two offline devices converge on move, color and width after restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'v2-two-clients-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final seedFile = File('${directory.path}/seed.sqlite');
      final aFile = File('${directory.path}/device-a.sqlite');
      final bFile = File('${directory.path}/device-b.sqlite');
      final seedDb = NotesDatabase(NativeDatabase(seedFile));
      final seeded = NotebookRepository(seedDb);
      final document = await seeded.createNotebook();
      final sourceId = document.pages.single.id;
      const destinationId = 'rebase-page-two';
      const objectId = 'rebase-stroke';
      final seedStore = OperationStore(seedDb);
      final seedProjector = EditorSqliteProjector(seedDb);
      final initial = await seedStore.writeLocalBatch(
        actorId: 'seed-device',
        documentId: document.uid,
        operations: [
          const LocalOperationDraft(
            kind: OperationKind.pageCreate,
            objectId: destinationId,
            payload: {
              'value': {'title': 'Second page', 'isBookmarked': false},
            },
          ),
          LocalOperationDraft(
            kind: OperationKind.strokeCreate,
            pageId: sourceId,
            objectId: objectId,
            payload: const {
              'value': {
                'objectType': 'stroke',
                'colorValue': 0xFF123456,
                'width': 2.0,
                'toolIndex': 0,
                'sortIndex': 0,
                'points': [
                  [10.0, 12.0, 0.5],
                ],
              },
            },
          ),
        ],
        apply: seedProjector.apply,
      );
      await seedStore.acknowledgeBatch({
        initial[0].operationId: 1,
        initial[1].operationId: 2,
      });
      await seedDb.close();
      await seedFile.copy(aFile.path);
      await seedFile.copy(bFile.path);

      final aDb = NotesDatabase(NativeDatabase(aFile));
      final bDb = NotesDatabase(NativeDatabase(bFile));
      final aStore = OperationStore(aDb);
      final bStore = OperationStore(bDb);
      final aProjector = EditorSqliteProjector(aDb);
      final bProjector = EditorSqliteProjector(bDb);

      final moved = await aStore.writeLocal(
        actorId: 'offline-device-a',
        documentId: document.uid,
        pageId: sourceId,
        objectId: objectId,
        kind: OperationKind.objectMove,
        payload: const {'toPageId': destinationId, 'sortIndex': 5},
        apply: aProjector.apply,
      );
      final styled = await bStore.writeLocal(
        actorId: 'offline-device-b',
        documentId: document.uid,
        pageId: sourceId,
        objectId: objectId,
        kind: OperationKind.objectSet,
        payload: const {
          'properties': {'colorValue': 0xFFAABBCC, 'width': 3.5},
        },
        apply: bProjector.apply,
      );
      expect(moved.operationId, isNot(styled.operationId));
      expect(moved.actorSeq, 1);
      expect(styled.actorSeq, 1);
      expect((await aStore.pending()).single.operationId, moved.operationId);
      expect((await bStore.pending()).single.operationId, styled.operationId);

      // Each client receives the other offline operation in a different
      // projection state. Both must converge without changing local IDs.
      expect(
        await aStore.applyRemote(
          styled,
          serverSequence: 4,
          apply: () => aProjector.apply(styled),
        ),
        isTrue,
      );
      expect(
        await bStore.applyRemote(
          moved,
          serverSequence: 3,
          apply: () => bProjector.apply(moved),
        ),
        isTrue,
      );
      await aStore.acknowledge(moved.operationId, serverSequence: 3);
      await bStore.acknowledge(styled.operationId, serverSequence: 4);
      expect(await aStore.pending(includeDeferred: true), isEmpty);
      expect(await bStore.pending(includeDeferred: true), isEmpty);

      Future<void> verify(NotesDatabase db) async {
        final notebook = (await NotebookRepository(
          db,
        ).getNotebook(document.uid))!;
        expect(notebook.pages, hasLength(2));
        expect(notebook.pages.first.inkStrokes, isEmpty);
        expect(notebook.pages.last.inkStrokes, hasLength(1));
        final stroke = notebook.pages.last.inkStrokes.single;
        expect(stroke.id, objectId);
        expect(stroke.color.toARGB32(), 0xFFAABBCC);
        expect(stroke.width, 3.5);
        final store = OperationStore(db);
        expect(
          (await store.operation(moved.operationId))!.toJson(),
          moved.toJson(),
        );
        expect(
          (await store.operation(styled.operationId))!.toJson(),
          styled.toJson(),
        );
      }

      await verify(aDb);
      await verify(bDb);
      await aDb.close();
      await bDb.close();

      final restoredA = NotesDatabase(NativeDatabase(aFile));
      final restoredB = NotesDatabase(NativeDatabase(bFile));
      try {
        await verify(restoredA);
        await verify(restoredB);
      } finally {
        await restoredA.close();
        await restoredB.close();
      }
    },
  );

  test('two competing offline moves converge with one persistent UID', () async {
    final directory = await Directory.systemTemp.createTemp(
      'v2-concurrent-moves-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final seedFile = File('${directory.path}/seed.sqlite');
    final aFile = File('${directory.path}/a.sqlite');
    final bFile = File('${directory.path}/b.sqlite');
    final seedDb = NotesDatabase(NativeDatabase(seedFile));
    final notebook = await NotebookRepository(seedDb).createNotebook();
    final source = notebook.pages.single.id;
    const firstDestination = 'first-destination';
    const winningDestination = 'winning-destination';
    const objectId = 'competing-move-ink';
    final seedStore = OperationStore(seedDb);
    final seeded = await seedStore.writeLocalBatch(
      actorId: 'seed-device',
      documentId: notebook.uid,
      operations: [
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: firstDestination,
          payload: {
            'value': {'title': 'First', 'isBookmarked': false},
          },
        ),
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: winningDestination,
          payload: {
            'value': {'title': 'Second', 'isBookmarked': false},
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: source,
          objectId: objectId,
          payload: const {
            'value': {
              'objectType': 'stroke',
              'colorValue': 0xFF123456,
              'width': 2.0,
              'toolIndex': 0,
              'sortIndex': 0,
              'points': [
                [10.0, 12.0, 0.5],
              ],
            },
          },
        ),
      ],
      apply: EditorSqliteProjector(seedDb).apply,
    );
    await seedStore.acknowledgeBatch({
      seeded[0].operationId: 1,
      seeded[1].operationId: 2,
      seeded[2].operationId: 3,
    });
    await seedDb.close();
    await seedFile.copy(aFile.path);
    await seedFile.copy(bFile.path);

    final aDb = NotesDatabase(NativeDatabase(aFile));
    final bDb = NotesDatabase(NativeDatabase(bFile));
    final aStore = OperationStore(aDb);
    final bStore = OperationStore(bDb);
    final aMove = await aStore.writeLocal(
      actorId: 'offline-actor-a',
      documentId: notebook.uid,
      pageId: source,
      objectId: objectId,
      kind: OperationKind.objectMove,
      payload: const {'toPageId': firstDestination, 'sortIndex': 2},
      apply: EditorSqliteProjector(aDb).apply,
    );
    final bMove = await bStore.writeLocal(
      actorId: 'offline-actor-z',
      documentId: notebook.uid,
      pageId: source,
      objectId: objectId,
      kind: OperationKind.objectMove,
      payload: const {'toPageId': winningDestination, 'sortIndex': 3},
      apply: EditorSqliteProjector(bDb).apply,
    );
    expect(aMove.actorSeq, 1);
    expect(bMove.actorSeq, 1);
    expect((await aStore.pending()).single.operationId, aMove.operationId);
    expect((await bStore.pending()).single.operationId, bMove.operationId);
    expect(
      await aStore.applyRemote(
        bMove,
        serverSequence: 5,
        apply: () => EditorSqliteProjector(aDb).apply(bMove),
      ),
      isTrue,
    );
    expect(
      await bStore.applyRemote(
        aMove,
        serverSequence: 4,
        apply: () => EditorSqliteProjector(bDb).apply(aMove),
      ),
      isTrue,
    );
    await aStore.acknowledge(aMove.operationId, serverSequence: 4);
    await bStore.acknowledge(bMove.operationId, serverSequence: 5);

    Future<void> verify(NotesDatabase db) async {
      final saved = (await NotebookRepository(db).getNotebook(notebook.uid))!;
      expect(saved.pages, hasLength(3));
      final allStrokes = saved.pages.expand((page) => page.inkStrokes);
      expect(allStrokes, hasLength(1));
      expect(saved.pages.last.inkStrokes.single.id, objectId);
      final ranks = await db.customSelect(
        'SELECT sort_index FROM ink_stroke_rows WHERE uid = ?',
        variables: [const Variable<String>(objectId)],
      ).get();
      expect(ranks.single.read<int>('sort_index'), 3);
      final store = OperationStore(db);
      expect(
        (await store.operation(aMove.operationId))!.toJson(),
        aMove.toJson(),
      );
      expect(
        (await store.operation(bMove.operationId))!.toJson(),
        bMove.toJson(),
      );
      expect(await store.pending(includeDeferred: true), isEmpty);
    }

    await verify(aDb);
    await verify(bDb);
    await aDb.close();
    await bDb.close();
    final reopenedA = NotesDatabase(NativeDatabase(aFile));
    final reopenedB = NotesDatabase(NativeDatabase(bFile));
    try {
      await verify(reopenedA);
      await verify(reopenedB);
    } finally {
      await reopenedA.close();
      await reopenedB.close();
    }
  });
}
