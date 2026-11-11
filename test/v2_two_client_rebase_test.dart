import 'dart:io';

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
      final directory = await Directory.systemTemp.createTemp('v2-two-clients-');
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
        final notebook =
            (await NotebookRepository(db).getNotebook(document.uid))!;
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
}
