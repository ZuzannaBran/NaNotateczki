import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:program/app/notes_app.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:uuid/uuid.dart';

import '../test/support/app_icon_check.dart';
import 'support/sqlite_runtime_check_stub.dart'
    if (dart.library.io) 'support/sqlite_runtime_check_io.dart';

const _isolated = bool.fromEnvironment('NANOTATECZKI_ISOLATED_CI');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bundled Material icons retain their glyphs on the platform',
    verifyAppIcons,
  );

  testWidgets(
    'native SQLite loads in the app and Drift worker after a restart',
    (tester) async {
      await tester.runAsync(verifyNativeSqliteRuntime);
    },
    skip: !_isolated || !supportsNativeSqliteRuntime,
  );

  testWidgets(
    'isolated platform DB creates, persists, renames and deletes a board',
    (tester) async {
      await tester.pumpWidget(const NotesApp());

      for (var attempt = 0; attempt < 70; attempt++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.byType(LibraryScreen).evaluate().isNotEmpty) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 75)),
        );
      }
      expect(find.byType(LibraryScreen), findsOneWidget);

      final context = tester.element(find.byType(LibraryScreen));
      final repository = Provider.of<NotebookRepository>(
        context,
        listen: false,
      );
      final library = Provider.of<LibraryController>(context, listen: false);

      final created = await library.createBoard();
      try {
        expect(created.kind, NotebookKind.board);
        final read = await repository.getNotebook(created.uid);
        expect(read?.uid, created.uid);
        expect(read?.pages, hasLength(1));

        final renamed = await repository.updateNotebookMetadata(
          created.uid,
          title: 'QA persisted board',
        );
        expect(renamed?.title, 'QA persisted board');

        await library.loadItems();
        final reloaded = await repository.getNotebook(created.uid);
        expect(reloaded?.title, 'QA persisted board');
        expect(library.items.any((item) => item.uid == created.uid), isTrue);
      } finally {
        await repository.deleteNotebook(created.uid);
        await library.loadItems();
      }

      expect(await repository.getNotebook(created.uid), isNull);
    },
    skip: !_isolated,
  );
  testWidgets(
    'isolated platform SQLite commits v2 text and rolls back invalid format',
    (tester) async {
      await tester.pumpWidget(const NotesApp());
      for (var attempt = 0; attempt < 70; attempt++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.byType(LibraryScreen).evaluate().isNotEmpty) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 75)),
        );
      }
      expect(find.byType(LibraryScreen), findsOneWidget);

      final context = tester.element(find.byType(LibraryScreen));
      final repository = Provider.of<NotebookRepository>(
        context,
        listen: false,
      );
      final store = OperationStore(repository.database);
      final projector = EditorSqliteProjector(repository.database);
      final documentId = const Uuid().v4();
      final pageId = const Uuid().v4();
      final actorId = 'platform-$documentId';
      const atomId = '12345678-1234-4234-8234-123456789abc';
      final now = DateTime.now().toUtc().toIso8601String();

      Future<List<OperationEnvelope>> pendingDocument() async {
        final entries = await store.pending(limit: 1000, includeDeferred: true);
        return entries.where((op) => op.documentId == documentId).toList();
      }

      try {
        final created = await store.writeLocalBatch(
          actorId: actorId,
          documentId: documentId,
          operations: [
            LocalOperationDraft(
              kind: OperationKind.documentCreate,
              payload: {
                'value': {
                  'title': 'Isolated v2 platform verification',
                  'folder': 'Notes',
                  'kindIndex': 0,
                  'createdAt': now,
                },
              },
            ),
            LocalOperationDraft(
              kind: OperationKind.pageCreate,
              objectId: pageId,
              payload: const {
                'value': {'title': 'Page 1', 'isBookmarked': false},
              },
            ),
            LocalOperationDraft(
              kind: OperationKind.objectCreate,
              pageId: pageId,
              objectId: 'platform-text',
              payload: const {
                'value': {
                  'objectType': 'text',
                  'dx': 10.0,
                  'dy': 20.0,
                  'width': 200.0,
                  'fontSize': 18.0,
                  'rotation': 0.0,
                  'colorValue': 0xFF222222,
                  'sortIndex': 0,
                },
              },
            ),
            LocalOperationDraft(
              kind: OperationKind.textInsert,
              pageId: pageId,
              objectId: 'platform-text',
              payload: const {
                'afterAtomId': null,
                'atoms': [
                  {'id': atomId, 'text': 'Hello  \n'},
                ],
              },
            ),
          ],
          apply: projector.apply,
        );
        expect(created, hasLength(4));
        final saved = (await repository.getNotebook(documentId))!;
        expect(saved.pages.single.textBlocks.single.text, 'Hello  ');
        expect(await pendingDocument(), hasLength(4));

        await expectLater(
          store.writeLocalBatch(
            actorId: actorId,
            documentId: documentId,
            operations: [
              LocalOperationDraft(
                kind: OperationKind.textFormat,
                pageId: pageId,
                objectId: 'platform-text',
                payload: const {
                  'atomIds': ['00000000-0000-4000-8000-000000000099'],
                  'attributes': {'bold': true},
                },
              ),
            ],
            apply: projector.apply,
          ),
          throwsFormatException,
        );
        expect(await pendingDocument(), hasLength(4));
        expect(
          (await repository.getNotebook(
            documentId,
          ))!.pages.single.textBlocks.single.deltaJson,
          saved.pages.single.textBlocks.single.deltaJson,
        );

        final formatted = await store.writeLocalBatch(
          actorId: actorId,
          documentId: documentId,
          operations: [
            LocalOperationDraft(
              kind: OperationKind.textFormat,
              pageId: pageId,
              objectId: 'platform-text',
              payload: const {
                'atomIds': [atomId],
                'attributes': {'bold': true},
              },
            ),
          ],
          apply: projector.apply,
        );
        expect(formatted.single.actorSeq, 5);
        expect(
          (await repository.getNotebook(
            documentId,
          ))!.pages.single.textBlocks.single.deltaJson,
          contains('"bold":true'),
        );
        expect(await pendingDocument(), hasLength(5));
      } finally {
        if (await repository.getNotebook(documentId) != null) {
          await store.writeLocal(
            actorId: actorId,
            documentId: documentId,
            kind: OperationKind.documentDelete,
            payload: const {},
            apply: projector.apply,
          );
        }
      }
    },
    skip: !_isolated,
  );
}
