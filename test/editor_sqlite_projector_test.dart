import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/verified_editor_asset_buffer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:uuid/uuid.dart';

Map<String, dynamic> _stroke() => {
  'objectType': 'stroke',
  'colorValue': 0xFF123456,
  'width': 2.0,
  'toolIndex': 0,
  'sortIndex': 0,
  'points': [
    [10.0, 12.0, 0.5],
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NotesDatabase database;
  late NotebookRepository notebooks;
  late OperationStore store;
  late EditorSqliteProjector projector;
  late String documentId;
  late String pageId;

  setUp(() async {
    database = NotesDatabase(NativeDatabase.memory());
    notebooks = NotebookRepository(database);
    store = OperationStore(database);
    projector = EditorSqliteProjector(database);
    final notebook = await notebooks.createNotebook();
    documentId = notebook.uid;
    pageId = notebook.pages.single.id;
  });

  tearDown(() async {
    await database.close();
  });

  Future<List<OperationEnvelope>> write(List<LocalOperationDraft> drafts) {
    return store.writeLocalBatch(
      actorId: 'v2-editor',
      documentId: documentId,
      operations: drafts,
      apply: projector.apply,
    );
  }

  Future<List<Map<String, dynamic>>> inkRows() async {
    final rows = await database
        .customSelect(
          'SELECT uid, points_json, color_value, sort_index '
          'FROM ink_stroke_rows WHERE page_uid = ?',
          variables: [Variable<String>(pageId)],
        )
        .get();
    return [for (final row in rows) row.data];
  }

  test('legacy eraser migration cannot rewrite a v2 ink document', () async {
    await write([
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: 'durable-stroke',
        payload: {'value': _stroke()},
      ),
    ]);
    await database.customStatement(
      'INSERT INTO ink_stroke_rows '
      '(uid, page_uid, color_value, width, tool_index, '
      'points_json, sort_index) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        'legacy-eraser',
        pageId,
        0xFFFFFFFF,
        20.0,
        DrawingTool.eraserArea.index,
        jsonEncode([
          {'dx': 90.0, 'dy': 90.0, 'pressure': 1.0},
          {'dx': 91.0, 'dy': 91.0, 'pressure': 1.0},
        ]),
        1,
      ],
    );
    Future<List<String>> persistedIds() async {
      final rows = await database
          .customSelect(
            'SELECT uid FROM ink_stroke_rows WHERE page_uid = ? ORDER BY uid',
            variables: [Variable<String>(pageId)],
          )
          .get();
      return [for (final row in rows) row.read<String>('uid')];
    }

    final beforeRead = await persistedIds();
    expect(beforeRead, contains('legacy-eraser'));
    final freshRepository = NotebookRepository(database);
    expect(await freshRepository.getNotebook(documentId), isNotNull);
    expect(await persistedIds(), beforeRead);
    expect(await store.pending(), hasLength(1));
  });

  test('a fresh repository cannot overwrite committed v2 history', () async {
    await write([
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: 'protected-ink',
        payload: {'value': _stroke()},
      ),
    ]);
    final reopenedRepository = NotebookRepository(database);
    final existing = (await reopenedRepository.getNotebook(documentId))!;
    expect(existing.pages.first.inkStrokes.single.id, 'protected-ink');

    await expectLater(
      reopenedRepository.saveNotebook(existing),
      throwsStateError,
    );
    await expectLater(
      reopenedRepository.saveNotebookPages(existing, {pageId}),
      throwsStateError,
    );
    await expectLater(
      reopenedRepository.updateNotebookMetadata(
        documentId,
        title: 'Legacy overwrite',
      ),
      throwsStateError,
    );
    await expectLater(
      reopenedRepository.importNotebooksAtomically([existing]),
      throwsStateError,
    );
    await expectLater(
      reopenedRepository.deleteNotebook(documentId),
      throwsStateError,
    );
    expect(
      (await reopenedRepository.getNotebook(
        documentId,
      ))!.pages.first.inkStrokes.single.id,
      'protected-ink',
    );

    // A different document without operational history remains writable.
    final sibling = await reopenedRepository.createNotebook();
    expect(await reopenedRepository.saveNotebook(sibling), isTrue);
  });

  test('rapid v2 commits never invent future notebook timestamps', () async {
    final original = (await notebooks.getNotebook(documentId))!.updatedAt;
    await write([
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: 'timestamp-ink',
        payload: {'value': _stroke()},
      ),
    ]);
    final first = (await notebooks.getNotebook(documentId))!.updatedAt;
    expect(!first.isBefore(original), isTrue);
    expect(
      first.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 1))),
      isFalse,
    );
    await write([
      LocalOperationDraft(
        kind: OperationKind.objectSet,
        pageId: pageId,
        objectId: 'timestamp-ink',
        payload: const {
          'properties': {'width': 3.5},
        },
      ),
    ]);
    final second = (await notebooks.getNotebook(documentId))!.updatedAt;
    expect(!second.isBefore(first), isTrue);
    expect(
      second.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 1))),
      isFalse,
    );
    expect((await store.pending()).map((operation) => operation.actorSeq), [
      1,
      2,
    ]);
    final previousOutbox = await store.pending();
    await expectLater(
      write([
        LocalOperationDraft(
          kind: OperationKind.objectSet,
          pageId: pageId,
          objectId: 'timestamp-ink',
          payload: const {
            'properties': {'width': -1.0},
          },
        ),
      ]),
      throwsFormatException,
    );
    final afterRollback = (await notebooks.getNotebook(documentId))!.updatedAt;
    expect(afterRollback, second);
    expect(await store.pending(), hasLength(previousOutbox.length));
  });

  test(
    'ink create, transform and delete persist as atomic operations',
    () async {
      final added = await write([
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: 'stroke-one',
          payload: {'value': _stroke()},
        ),
      ]);
      expect(added, hasLength(1));
      expect(await inkRows(), hasLength(1));
      expect(
        (await store.pending()).single.operationId,
        added.single.operationId,
      );

      await write([
        LocalOperationDraft(
          kind: OperationKind.objectTransform,
          pageId: pageId,
          objectId: 'stroke-one',
          payload: {
            'properties': {
              'points': [
                [2.0, 3.0, 0.8],
              ],
            },
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.objectSet,
          pageId: pageId,
          objectId: 'stroke-one',
          payload: {
            'properties': {'colorValue': 0xFFABCDEF},
          },
        ),
      ]);
      final after = (await notebooks.getNotebook(documentId))!;
      expect(after.pages.single.inkStrokes.single.points.single.dx, 2);
      expect(after.pages.single.inkStrokes.single.color.toARGB32(), 0xFFABCDEF);

      await write([
        LocalOperationDraft(
          kind: OperationKind.objectDelete,
          pageId: pageId,
          objectId: 'stroke-one',
          payload: const {},
        ),
      ]);
      expect(await inkRows(), isEmpty);
      expect(
        await store.isTombstoned(
          documentId,
          'object',
          'stroke-one',
          pageId: pageId,
        ),
        isTrue,
      );
      await expectLater(
        write([
          LocalOperationDraft(
            kind: OperationKind.strokeCreate,
            pageId: pageId,
            objectId: 'stroke-one',
            payload: {'value': _stroke()},
          ),
        ]),
        throwsStateError,
      );
    },
  );

  test(
    'invalid second operation rolls back projection and actor sequence',
    () async {
      await expectLater(
        write([
          LocalOperationDraft(
            kind: OperationKind.strokeCreate,
            pageId: pageId,
            objectId: 'stroke-one',
            payload: {'value': _stroke()},
          ),
          const LocalOperationDraft(
            kind: OperationKind.objectSet,
            pageId: 'wrong-page',
            objectId: 'stroke-one',
            payload: {
              'properties': {'colorValue': 0xFF987654},
            },
          ),
        ]),
        throwsStateError,
      );
      expect(await inkRows(), isEmpty);
      expect(await store.pending(), isEmpty);
      final committed = await write([
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: 'stroke-one',
          payload: {'value': _stroke()},
        ),
      ]);
      expect(committed.single.actorSeq, 1);
    },
  );

  test('remote operation commits projection and checkpoint once', () async {
    final local = (await write([
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: 'stroke-one',
        payload: {'value': _stroke()},
      ),
    ])).single;
    final remote = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'remote-actor',
      actorSeq: 1,
      logicalClock: local.logicalClock + 1,
      documentId: documentId,
      pageId: pageId,
      objectId: 'stroke-one',
      kind: OperationKind.objectReorder,
      payload: const {
        'properties': {'sortIndex': 3},
      },
      dependencies: [local.operationId],
    );
    expect(
      await store.applyRemote(
        remote,
        serverSequence: 2,
        checkpointScope: 'v2-test',
        apply: () => projector.apply(remote),
      ),
      isTrue,
    );
    expect((await inkRows()).single['sort_index'], 3);
    expect(await store.checkpoint('v2-test'), 2);
    expect(
      await store.applyRemote(
        remote,
        serverSequence: 2,
        checkpointScope: 'v2-test',
        apply: () => projector.apply(remote),
      ),
      isFalse,
    );
    expect((await inkRows()).single['sort_index'], 3);
    expect((await store.pending()), hasLength(1));
  });

  test('Quill text remains recoverable from journal atoms', () async {
    const atomA = '11111111-1111-4111-8111-111111111111';
    const atomB = '22222222-2222-4222-8222-222222222222';
    const atomNewline = '33333333-3333-4333-8333-333333333333';
    final committed = await write([
      LocalOperationDraft(
        kind: OperationKind.objectCreate,
        pageId: pageId,
        objectId: 'text-one',
        payload: const {
          'value': {
            'objectType': 'text',
            'dx': 12.0,
            'dy': 14.0,
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
        objectId: 'text-one',
        payload: const {
          'afterAtomId': null,
          'atoms': [
            {
              'id': atomA,
              'text': 'H',
              'attributes': {'bold': true},
            },
            {
              'id': atomB,
              'text': 'i',
              'attributes': {'bold': true},
            },
            {'id': atomNewline, 'text': '\n'},
          ],
        },
      ),
    ]);
    expect(committed, hasLength(2));
    final saved = await notebooks.getNotebook(documentId);
    expect(saved?.pages.single.textBlocks.single.text, 'Hi');
    expect(saved?.pages.single.textBlocks.single.deltaJson, contains('bold'));

    final durable = await store.textAtoms(
      documentId: documentId,
      pageId: pageId,
      objectId: 'text-one',
    );
    expect(durable, hasLength(3));
    await write([
      LocalOperationDraft(
        kind: OperationKind.textFormat,
        pageId: pageId,
        objectId: 'text-one',
        payload: const {
          'atomIds': [atomA, atomB],
          'attributes': {'bold': null, 'italic': true},
        },
      ),
      LocalOperationDraft(
        kind: OperationKind.textDelete,
        pageId: pageId,
        objectId: 'text-one',
        payload: const {
          'atomIds': [atomA],
        },
      ),
    ]);
    final changed = (await notebooks.getNotebook(
      documentId,
    ))!.pages.single.textBlocks.single;
    expect(changed.text, 'i');
    expect(changed.deltaJson, contains('italic'));
    expect(changed.deltaJson, isNot(contains('"bold":true')));
    expect(
      await store.textAtoms(
        documentId: documentId,
        pageId: pageId,
        objectId: 'text-one',
      ),
      hasLength(3),
    );
  });

  for (final reverseOrder in [false, true]) {
    test(
      'concurrent Quill replay survives restart, reverse=$reverseOrder',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'nn-concurrent-quill-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/notes.sqlite');
        var reopenedDatabase = NotesDatabase(NativeDatabase(file));
        addTearDown(() => reopenedDatabase.close());
        final isolatedRepository = NotebookRepository(reopenedDatabase);
        final isolatedStore = OperationStore(reopenedDatabase);
        final isolatedProjector = EditorSqliteProjector(reopenedDatabase);
        final notebook = await isolatedRepository.createNotebook();
        final page = notebook.pages.single.id;

        const initialAtom = '11111111-1111-4111-8111-111111111111';
        const newlineAtom = '22222222-2222-4222-8222-222222222222';
        const alphaAtom = '33333333-3333-4333-8333-333333333333';
        const betaAtom = '44444444-4444-4444-8444-444444444444';
        const objectId = 'concurrent-text';

        final created = await isolatedStore.writeLocalBatch(
          actorId: 'quill-seed',
          documentId: notebook.uid,
          operations: [
            LocalOperationDraft(
              kind: OperationKind.objectCreate,
              pageId: page,
              objectId: objectId,
              payload: const {
                'value': {
                  'objectType': 'text',
                  'dx': 0.0,
                  'dy': 0.0,
                  'width': 200.0,
                  'fontSize': 18.0,
                  'rotation': 0.0,
                  'colorValue': 0xFF000000,
                  'sortIndex': 0,
                },
              },
            ),
            LocalOperationDraft(
              kind: OperationKind.textInsert,
              pageId: page,
              objectId: objectId,
              payload: const {
                'afterAtomId': null,
                'atoms': [
                  {'id': initialAtom, 'text': 'A'},
                  {'id': newlineAtom, 'text': '\n'},
                ],
              },
            ),
          ],
          apply: isolatedProjector.apply,
        );
        final seed = created.last;

        OperationEnvelope concurrent({
          required String actor,
          required int clock,
          required String atomId,
          required String value,
        }) => OperationEnvelope(
          operationId: const Uuid().v4(),
          actorId: actor,
          actorSeq: 1,
          logicalClock: clock,
          documentId: notebook.uid,
          pageId: page,
          objectId: objectId,
          kind: OperationKind.textInsert,
          payload: {
            'afterAtomId': initialAtom,
            'atoms': [
              {'id': atomId, 'text': value},
            ],
          },
          dependencies: [seed.operationId],
        );
        final alpha = concurrent(
          actor: 'quill-alpha',
          clock: 30,
          atomId: alphaAtom,
          value: 'x',
        );
        final beta = concurrent(
          actor: 'quill-beta',
          clock: 40,
          atomId: betaAtom,
          value: 'y',
        );
        final format = OperationEnvelope(
          operationId: const Uuid().v4(),
          actorId: 'quill-format',
          actorSeq: 1,
          logicalClock: 50,
          documentId: notebook.uid,
          pageId: page,
          objectId: objectId,
          kind: OperationKind.textFormat,
          payload: const {
            'atomIds': [initialAtom],
            'attributes': {'bold': true},
          },
          dependencies: [seed.operationId],
        );

        final order = reverseOrder
            ? [beta, alpha, format]
            : [alpha, beta, format];
        for (var index = 0; index < order.length; index++) {
          final operation = order[index];
          expect(
            await isolatedStore.applyRemote(
              operation,
              serverSequence: index + 1,
              checkpointScope: 'quill-concurrent',
              apply: () => isolatedProjector.apply(operation),
            ),
            isTrue,
          );
        }

        final savedNotebook = await isolatedRepository.getNotebook(
          notebook.uid,
        );
        final saved = savedNotebook!.pages.single.textBlocks.single;
        expect(saved.text, 'Ayx');
        expect(jsonDecode(saved.deltaJson!), [
          {
            'insert': 'A',
            'attributes': {'bold': true},
          },
          {'insert': 'yx\n'},
        ]);
        expect(await isolatedStore.pending(), hasLength(created.length));
        expect(await isolatedStore.checkpoint('quill-concurrent'), 3);

        await reopenedDatabase.close();
        reopenedDatabase = NotesDatabase(NativeDatabase(file));
        final reopenedRepository = NotebookRepository(reopenedDatabase);
        final persistedNotebook = await reopenedRepository.getNotebook(
          notebook.uid,
        );
        final persisted = persistedNotebook!.pages.single.textBlocks.single;
        expect(persisted.text, saved.text);
        expect(persisted.deltaJson, saved.deltaJson);

        final recoveredStore = OperationStore(reopenedDatabase);
        final recoveredProjector = EditorSqliteProjector(reopenedDatabase);
        expect(
          await recoveredStore.textAtoms(
            documentId: notebook.uid,
            pageId: page,
            objectId: objectId,
          ),
          hasLength(4),
        );
        expect(await recoveredStore.pending(), hasLength(created.length));
        expect(await recoveredStore.checkpoint('quill-concurrent'), 3);
        expect(
          await recoveredStore.applyRemote(
            order.last,
            serverSequence: 3,
            checkpointScope: 'quill-concurrent',
            apply: () => recoveredProjector.apply(order.last),
          ),
          isFalse,
        );
        final duplicateNotebook = await reopenedRepository.getNotebook(
          notebook.uid,
        );
        expect(
          duplicateNotebook!.pages.single.textBlocks.single.deltaJson,
          saved.deltaJson,
        );
      },
    );
  }

  test('invalid text gesture rolls back atom history and SQLite', () async {
    await expectLater(
      write([
        const LocalOperationDraft(
          kind: OperationKind.objectCreate,
          pageId: 'wrong-page',
          objectId: 'text-one',
          payload: {
            'value': {
              'objectType': 'text',
              'dx': 1.0,
              'dy': 1.0,
              'width': 100.0,
              'fontSize': 18.0,
              'rotation': 0.0,
              'colorValue': 0xFF000000,
              'sortIndex': 0,
            },
          },
        ),
      ]),
      throwsStateError,
    );
    expect(await store.pending(), isEmpty);
    expect(
      await store.textAtoms(
        documentId: documentId,
        pageId: pageId,
        objectId: 'text-one',
      ),
      isEmpty,
    );
  });

  test('concurrent ink fields converge despite reverse delivery', () async {
    final create = (await write([
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: 'concurrent-ink',
        payload: {'value': _stroke()},
      ),
    ])).single;
    OperationEnvelope style({
      required String actor,
      required int clock,
      required Map<String, dynamic> properties,
    }) => OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: actor,
      actorSeq: 1,
      logicalClock: clock,
      documentId: documentId,
      pageId: pageId,
      objectId: 'concurrent-ink',
      kind: OperationKind.objectSet,
      payload: {'properties': properties},
      dependencies: [create.operationId],
    );
    final newer = style(
      actor: 'newer-device',
      clock: 40,
      properties: {'colorValue': 0xFFAA0000},
    );
    final older = style(
      actor: 'older-device',
      clock: 30,
      properties: {'colorValue': 0xFF00AA00, 'width': 4.0},
    );
    await store.applyRemote(
      newer,
      serverSequence: 1,
      checkpointScope: 'ink-fields',
      apply: () => projector.apply(newer),
    );
    await store.applyRemote(
      older,
      serverSequence: 2,
      checkpointScope: 'ink-fields',
      apply: () => projector.apply(older),
    );
    final persisted = (await notebooks.getNotebook(
      documentId,
    ))!.pages.first.inkStrokes.single;
    expect(persisted.color.toARGB32(), 0xFFAA0000);
    expect(persisted.width, 4.0);
    expect(await store.checkpoint('ink-fields'), 2);
  });

  test('page metadata uses field rank rather than receipt order', () async {
    OperationEnvelope renamed({
      required String actor,
      required int clock,
      required String title,
    }) => OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: actor,
      actorSeq: 1,
      logicalClock: clock,
      documentId: documentId,
      objectId: pageId,
      kind: OperationKind.pageSet,
      payload: {
        'properties': {'title': title},
      },
      dependencies: const [],
    );
    final newer = renamed(
      actor: 'remote-newer',
      clock: 20,
      title: 'Newer title',
    );
    final older = renamed(
      actor: 'remote-older',
      clock: 10,
      title: 'Stale title',
    );
    await store.applyRemote(
      newer,
      serverSequence: 1,
      checkpointScope: 'page-fields',
      apply: () => projector.apply(newer),
    );
    await store.applyRemote(
      older,
      serverSequence: 2,
      checkpointScope: 'page-fields',
      apply: () => projector.apply(older),
    );
    expect(
      (await notebooks.getNotebook(documentId))?.pages.first.title,
      'Newer title',
    );
  });

  test('equal clocks resolve object colors by actor identity', () async {
    final created = (await write([
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: 'tie-ink',
        payload: {'value': _stroke()},
      ),
    ])).single;
    OperationEnvelope update(String actor, int color) => OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: actor,
      actorSeq: 1,
      logicalClock: 5,
      documentId: documentId,
      pageId: pageId,
      objectId: 'tie-ink',
      kind: OperationKind.objectSet,
      payload: {
        'properties': {'colorValue': color},
      },
      dependencies: [created.operationId],
    );
    final winning = update('actor-z', 0xFF112233);
    final losing = update('actor-a', 0xFF998877);
    await store.applyRemote(
      winning,
      serverSequence: 1,
      apply: () => projector.apply(winning),
    );
    await store.applyRemote(
      losing,
      serverSequence: 2,
      apply: () => projector.apply(losing),
    );
    expect(
      (await notebooks.getNotebook(
        documentId,
      ))!.pages.first.inkStrokes.single.color.toARGB32(),
      0xFF112233,
    );
  });

  for (final reverseOrder in [false, true]) {
    test('concurrent ink moves converge, reverse=$reverseOrder', () async {
      final setup = await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: 'move-destination-a',
          payload: {
            'value': {'title': 'A', 'isBookmarked': false},
          },
        ),
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: 'move-destination-b',
          payload: {
            'value': {'title': 'B', 'isBookmarked': false},
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: 'concurrent-move-ink',
          payload: {'value': _stroke()},
        ),
      ]);
      OperationEnvelope remoteMove({
        required String actor,
        required String destination,
        required int logicalClock,
      }) => OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: actor,
        actorSeq: 1,
        logicalClock: logicalClock,
        documentId: documentId,
        pageId: pageId,
        objectId: 'concurrent-move-ink',
        kind: OperationKind.objectMove,
        payload: {'toPageId': destination, 'sortIndex': 0},
        dependencies: [setup.last.operationId],
      );
      final first = remoteMove(
        actor: 'move-actor-a',
        destination: 'move-destination-a',
        logicalClock: 40,
      );
      final winning = remoteMove(
        actor: 'move-actor-z',
        destination: 'move-destination-b',
        logicalClock: 50,
      );
      final order = reverseOrder ? [winning, first] : [first, winning];
      for (var i = 0; i < order.length; i++) {
        final move = order[i];
        expect(
          await store.applyRemote(
            move,
            serverSequence: i + 1,
            checkpointScope: 'concurrent-ink',
            apply: () => projector.apply(move),
          ),
          isTrue,
        );
      }
      final result = (await notebooks.getNotebook(documentId))!;
      expect(result.pages.first.inkStrokes, isEmpty);
      expect(result.pages[1].inkStrokes, isEmpty);
      expect(result.pages[2].inkStrokes.single.id, 'concurrent-move-ink');
      expect(await store.checkpoint('concurrent-ink'), 2);
      expect(
        await store.isTombstoned(
          documentId,
          'object',
          'concurrent-move-ink',
          pageId: pageId,
        ),
        isFalse,
      );
    });
  }

  for (final moveFirst in [false, true]) {
    test('move keeps newer z-order, moveFirst=$moveFirst', () async {
      const destination = 'ranked-move-destination';
      final setup = await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: destination,
          payload: {
            'value': {'title': 'Destination', 'isBookmarked': false},
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: 'ranked-move-ink',
          payload: {'value': _stroke()},
        ),
      ]);
      final move = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'move-actor',
        actorSeq: 1,
        logicalClock: 50,
        documentId: documentId,
        pageId: pageId,
        objectId: 'ranked-move-ink',
        kind: OperationKind.objectMove,
        payload: const {'toPageId': destination, 'sortIndex': 2},
        dependencies: [setup.last.operationId],
      );
      final reorder = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'reorder-actor',
        actorSeq: 1,
        logicalClock: 60,
        documentId: documentId,
        pageId: moveFirst ? destination : pageId,
        objectId: 'ranked-move-ink',
        kind: OperationKind.objectReorder,
        payload: const {
          'properties': {'sortIndex': 9},
        },
        dependencies: [setup.last.operationId],
      );
      final delivered = moveFirst ? [move, reorder] : [reorder, move];
      for (var i = 0; i < delivered.length; i++) {
        final operation = delivered[i];
        expect(
          await store.applyRemote(
            operation,
            serverSequence: i + 1,
            checkpointScope: 'ranked-move-z-order',
            apply: () => projector.apply(operation),
          ),
          isTrue,
        );
      }
      final rows = await database
          .customSelect(
            'SELECT page_uid, sort_index FROM ink_stroke_rows WHERE uid = ?',
            variables: [const Variable<String>('ranked-move-ink')],
          )
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.read<String>('page_uid'), destination);
      expect(rows.single.read<int>('sort_index'), 9);
      expect(await store.checkpoint('ranked-move-z-order'), 2);
      expect(
        (await store.pending()).map((op) => op.operationId),
        setup.map((op) => op.operationId),
      );
      expect(
        await store.applyRemote(
          delivered.last,
          serverSequence: 2,
          checkpointScope: 'ranked-move-z-order',
          apply: () => projector.apply(delivered.last),
        ),
        isFalse,
      );
    });
  }

  test(
    'object.move preserves the stroke identity across notebook pages',
    () async {
      const destination = 'second-page';
      await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: destination,
          payload: {
            'value': {'title': 'Second', 'isBookmarked': false},
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: 'moved-stroke',
          payload: {'value': _stroke()},
        ),
      ]);
      await write([
        LocalOperationDraft(
          kind: OperationKind.objectMove,
          pageId: pageId,
          objectId: 'moved-stroke',
          payload: const {'toPageId': destination, 'sortIndex': 2},
        ),
      ]);
      final notebook = (await notebooks.getNotebook(documentId))!;
      expect(notebook.pages.first.inkStrokes, isEmpty);
      expect(notebook.pages.last.inkStrokes.single.id, 'moved-stroke');
      expect(
        (await database
                .customSelect(
                  'SELECT sort_index FROM ink_stroke_rows '
                  'WHERE uid = ? AND page_uid = ?',
                  variables: [
                    const Variable<String>('moved-stroke'),
                    const Variable<String>(destination),
                  ],
                )
                .get())
            .single
            .read<int>('sort_index'),
        2,
      );
      expect(
        await store.isTombstoned(
          documentId,
          'object',
          'moved-stroke',
          pageId: pageId,
        ),
        isFalse,
      );
      expect(
        await store.isTombstoned(
          documentId,
          'object',
          'moved-stroke',
          pageId: destination,
        ),
        isFalse,
      );
      await expectLater(
        write([
          LocalOperationDraft(
            kind: OperationKind.objectMove,
            pageId: pageId,
            objectId: 'moved-stroke',
            payload: const {'toPageId': destination, 'sortIndex': 2},
          ),
        ]),
        throwsUnsupportedError,
      );
      expect(
        (await notebooks.getNotebook(
          documentId,
        ))!.pages.last.inkStrokes.single.id,
        'moved-stroke',
      );
    },
  );

  test('ambiguous cross-layer identity cannot delete either object', () async {
    await write([
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: 'duplicate',
        payload: {'value': _stroke()},
      ),
    ]);
    await database.customStatement(
      'INSERT INTO text_block_rows '
      '(uid, page_uid, text, delta_json, font_size, color_value, '
      'width, rotation, dx, dy, sort_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'duplicate',
        pageId,
        '',
        null,
        18.0,
        0xFF000000,
        100.0,
        0.0,
        0.0,
        0.0,
        0,
      ],
    );
    await expectLater(
      write([
        LocalOperationDraft(
          kind: OperationKind.objectDelete,
          pageId: pageId,
          objectId: 'duplicate',
          payload: const {},
        ),
      ]),
      throwsStateError,
    );
    expect(await inkRows(), hasLength(1));
    expect(
      (await database
          .customSelect(
            'SELECT uid FROM text_block_rows WHERE uid = ?',
            variables: [const Variable<String>('duplicate')],
          )
          .get()),
      hasLength(1),
    );
    expect(
      await store.isTombstoned(
        documentId,
        'object',
        'duplicate',
        pageId: pageId,
      ),
      isFalse,
    );
  });

  test('stale Quill formatting blocks a new text operation', () async {
    const atom = '11111111-1111-4111-8111-111111111111';
    await write([
      LocalOperationDraft(
        kind: OperationKind.objectCreate,
        pageId: pageId,
        objectId: 'text-one',
        payload: const {
          'value': {
            'objectType': 'text',
            'dx': 0.0,
            'dy': 0.0,
            'width': 100.0,
            'fontSize': 18.0,
            'rotation': 0.0,
            'colorValue': 0xFF000000,
            'sortIndex': 0,
          },
        },
      ),
      LocalOperationDraft(
        kind: OperationKind.textInsert,
        pageId: pageId,
        objectId: 'text-one',
        payload: {
          'afterAtomId': null,
          'atoms': [
            {'id': atom, 'text': 'A'},
          ],
        },
      ),
    ]);
    final pendingBefore = await store.pending();
    await database.customStatement(
      'UPDATE text_block_rows SET delta_json = ? WHERE uid = ?',
      ['[{"insert":"A","attributes":{"bold":true}}]', 'text-one'],
    );
    await expectLater(
      write([
        LocalOperationDraft(
          kind: OperationKind.textFormat,
          pageId: pageId,
          objectId: 'text-one',
          payload: const {
            'atomIds': [atom],
            'attributes': {'italic': true},
          },
        ),
      ]),
      throwsStateError,
    );
    expect(await store.pending(), hasLength(pendingBefore.length));
    final result = (await notebooks.getNotebook(documentId))!;
    expect(result.pages.single.textBlocks.single.text, 'A');
    expect(result.pages.single.textBlocks.single.deltaJson, contains('bold'));
  });

  for (final reverseOrder in [false, true]) {
    test('SQLite document title converges, reverse=$reverseOrder', () async {
      OperationEnvelope setTitle({
        required String actor,
        required String title,
      }) => OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: actor,
        actorSeq: 1,
        logicalClock: 70,
        dependencies: const [],
        documentId: documentId,
        kind: OperationKind.documentSet,
        payload: {
          'properties': {'title': title},
        },
      );
      final lower = setTitle(actor: 'a-peer', title: 'Earlier');
      final higher = setTitle(actor: 'z-peer', title: 'Winner');
      final order = reverseOrder ? [higher, lower] : [lower, higher];
      for (var i = 0; i < order.length; i++) {
        final remote = order[i];
        expect(
          await store.applyRemote(
            remote,
            serverSequence: i + 1,
            checkpointScope: 'document-title-rank',
            apply: () => projector.apply(remote),
          ),
          isTrue,
        );
      }
      final saved = (await notebooks.getNotebook(documentId))!;
      expect(saved.title, 'Winner');
      expect(await store.checkpoint('document-title-rank'), 2);
    });

    test('SQLite page title converges, reverse=$reverseOrder', () async {
      OperationEnvelope setPageTitle({
        required String actor,
        required String title,
      }) => OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: actor,
        actorSeq: 1,
        logicalClock: 70,
        dependencies: const [],
        documentId: documentId,
        objectId: pageId,
        kind: OperationKind.pageSet,
        payload: {
          'properties': {'title': title},
        },
      );
      final lower = setPageTitle(actor: 'a-peer', title: 'Earlier');
      final higher = setPageTitle(actor: 'z-peer', title: 'Winner');
      final order = reverseOrder ? [higher, lower] : [lower, higher];
      for (var i = 0; i < order.length; i++) {
        final remote = order[i];
        expect(
          await store.applyRemote(
            remote,
            serverSequence: i + 1,
            checkpointScope: 'page-title-rank',
            apply: () => projector.apply(remote),
          ),
          isTrue,
        );
      }
      final saved = (await notebooks.getNotebook(documentId))!;
      expect(saved.pages.single.title, 'Winner');
      expect(await store.checkpoint('page-title-rank'), 2);
    });

    test('SQLite ink LWW converges, reverse=$reverseOrder', () async {
      final created = await write([
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: 'same-ink-field',
          payload: {'value': _stroke()},
        ),
      ]);
      OperationEnvelope setWidth({
        required String actor,
        required double width,
        required int clock,
      }) => OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: actor,
        actorSeq: 1,
        logicalClock: clock,
        dependencies: [created.single.operationId],
        documentId: documentId,
        pageId: pageId,
        objectId: 'same-ink-field',
        kind: OperationKind.objectSet,
        payload: {
          'properties': {'width': width},
        },
      );
      final lower = setWidth(actor: 'a-peer', width: 3.0, clock: 40);
      final higher = setWidth(actor: 'z-peer', width: 7.0, clock: 40);
      final order = reverseOrder ? [higher, lower] : [lower, higher];
      for (var i = 0; i < order.length; i++) {
        final remote = order[i];
        expect(
          await store.applyRemote(
            remote,
            serverSequence: i + 1,
            checkpointScope: 'ink-scalar-rank',
            apply: () => projector.apply(remote),
          ),
          isTrue,
        );
      }
      final saved = (await notebooks.getNotebook(documentId))!;
      expect(saved.pages.single.inkStrokes.single.width, 7.0);
      expect(await store.checkpoint('ink-scalar-rank'), 2);
      expect((await store.pending()).map((op) => op.operationId), [
        created.single.operationId,
      ]);
    });

    test('SQLite stroke points converge, reverse=$reverseOrder', () async {
      final created = await write([
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: 'ranked-points',
          payload: {'value': _stroke()},
        ),
      ]);
      OperationEnvelope transform({
        required String actor,
        required int clock,
        required List<List<double>> points,
      }) => OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: actor,
        actorSeq: 1,
        logicalClock: clock,
        dependencies: [created.single.operationId],
        documentId: documentId,
        pageId: pageId,
        objectId: 'ranked-points',
        kind: OperationKind.objectTransform,
        payload: {
          'properties': {'points': points},
        },
      );
      final lower = transform(
        actor: 'tablet-a',
        clock: 50,
        points: [
          [11.0, 12.0, 0.5],
        ],
      );
      final higher = transform(
        actor: 'tablet-z',
        clock: 50,
        points: [
          [31.0, 32.0, 0.7],
          [33.0, 34.0, 0.8],
        ],
      );
      final order = reverseOrder ? [higher, lower] : [lower, higher];
      for (var i = 0; i < order.length; i++) {
        final remote = order[i];
        expect(
          await store.applyRemote(
            remote,
            serverSequence: i + 1,
            checkpointScope: 'ink-point-rank',
            apply: () => projector.apply(remote),
          ),
          isTrue,
        );
      }
      final saved = (await notebooks.getNotebook(documentId))!;
      final points = saved.pages.single.inkStrokes.single.points;
      expect(points, hasLength(2));
      expect(points.first.dx, 31.0);
      expect(points.last.dy, 34.0);
      expect(await store.checkpoint('ink-point-rank'), 2);
    });
  }

  test('image move relocates the durable asset reference atomically', () async {
    const target = 'media-destination';
    const imageId = 'existing-image';
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    await write([
      const LocalOperationDraft(
        kind: OperationKind.pageCreate,
        objectId: target,
        payload: {
          'value': {'title': 'Media', 'isBookmarked': false},
        },
      ),
    ]);
    await database.customStatement(
      'INSERT INTO image_block_rows '
      '(uid, page_uid, path, ocr_text, bytes, image_ext, image_mime, '
      'width, height, rotation, dx, dy, '
      'crop_left, crop_top, crop_right, crop_bottom, sort_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        imageId,
        pageId,
        '',
        '',
        bytes,
        'png',
        'image/png',
        100.0,
        80.0,
        0.0,
        10.0,
        20.0,
        0.0,
        0.0,
        1.0,
        1.0,
        0,
      ],
    );
    final move = LocalOperationDraft(
      kind: OperationKind.objectMove,
      pageId: pageId,
      objectId: imageId,
      payload: const {'toPageId': target, 'sortIndex': 0},
    );
    final queued = await store.pending();
    await expectLater(write([move]), throwsUnsupportedError);
    expect(await store.pending(), hasLength(queued.length));

    final sha = crypto.sha256.convert(bytes).toString();
    await store.attachAssetReference(
      documentId: documentId,
      pageId: pageId,
      objectId: imageId,
      assetId: 'media-asset-one',
      storagePath: 'sqlite-blob:$sha',
      checksumSha256: sha,
      byteLength: bytes.length,
    );
    await database.customStatement(
      'UPDATE image_block_rows SET bytes = ? WHERE uid = ?',
      [
        Uint8List.fromList([1, 2, 3, 4]),
        imageId,
      ],
    );
    final delete = LocalOperationDraft(
      kind: OperationKind.objectDelete,
      pageId: pageId,
      objectId: imageId,
      payload: const {},
    );
    final deletePage = LocalOperationDraft(
      kind: OperationKind.pageDelete,
      objectId: pageId,
      payload: const {},
    );
    for (final operation in [move, delete, deletePage]) {
      await expectLater(write([operation]), throwsStateError);
      expect(await store.pending(), hasLength(queued.length));
    }
    await database.customStatement(
      'UPDATE image_block_rows SET bytes = ? WHERE uid = ?',
      [bytes, imageId],
    );
    await write([
      move,
      const LocalOperationDraft(
        kind: OperationKind.objectSet,
        pageId: target,
        objectId: imageId,
        payload: {
          'properties': {'dx': 33.0, 'cropRight': 0.8},
        },
      ),
    ]);
    final saved = (await notebooks.getNotebook(documentId))!;
    expect(saved.pages.first.imageBlocks, isEmpty);
    expect(saved.pages.last.imageBlocks.single.id, imageId);
    expect(saved.pages.last.imageBlocks.single.position.dx, 33);
    expect(saved.pages.last.imageBlocks.single.cropRight, 0.8);
    expect(saved.pages.last.imageBlocks.single.bytes, orderedEquals(bytes));
    final references = await database
        .customSelect(
          'SELECT object_id FROM asset_references '
          'WHERE document_id = ? AND asset_id = ?',
          variables: [
            Variable<String>(documentId),
            const Variable<String>('media-asset-one'),
          ],
        )
        .get();
    expect(references, hasLength(1));
    expect(
      references.single.read<String>('object_id'),
      'page:${jsonEncode([target, imageId])}',
    );
    expect(
      await store.isTombstoned(documentId, 'object', imageId, pageId: pageId),
      isFalse,
    );
  });

  test(
    'remote image stays invisible until verified asset materialization',
    () async {
      final buffer = VerifiedEditorAssetBuffer();
      final activeProjector = EditorSqliteProjector(
        database,
        verifiedAssetBuffer: buffer,
      );
      final bytes = Uint8List.fromList([137, 80, 78, 71, 4, 3, 2, 1]);
      final receipt = <String, dynamic>{
        'assetId': 'remote-asset',
        'sha256': crypto.sha256.convert(bytes).toString(),
        'sizeBytes': bytes.length,
        'mediaType': 'image/png',
      };
      final created = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'remote-image-actor',
        actorSeq: 1,
        logicalClock: 1,
        dependencies: const [],
        documentId: documentId,
        pageId: pageId,
        objectId: 'remote-image',
        kind: OperationKind.objectCreate,
        payload: const {
          'value': {
            'objectType': 'image',
            'assetId': 'remote-asset',
            'dx': 11.0,
            'dy': 13.0,
            'width': 120.0,
            'height': 80.0,
            'rotation': 0.0,
            'cropLeft': 0.0,
            'cropTop': 0.0,
            'cropRight': 1.0,
            'cropBottom': 1.0,
            'sortIndex': 0,
          },
        },
      );
      final attached = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'remote-image-actor',
        actorSeq: 2,
        logicalClock: 2,
        documentId: documentId,
        pageId: pageId,
        objectId: 'remote-image',
        kind: OperationKind.assetAttach,
        payload: receipt,
        dependencies: [created.operationId],
      );
      expect(
        await store.applyRemote(
          created,
          serverSequence: 1,
          checkpointScope: 'remote-media',
          apply: () => activeProjector.apply(created),
        ),
        isTrue,
      );
      expect(await store.checkpoint('remote-media'), 1);
      expect(
        (await notebooks.getNotebook(documentId))!.pages.first.imageBlocks,
        isEmpty,
      );
      await expectLater(
        store.applyRemote(
          attached,
          serverSequence: 2,
          checkpointScope: 'remote-media',
          apply: () => activeProjector.apply(attached),
        ),
        throwsStateError,
      );
      expect(await store.operation(attached.operationId), isNull);
      expect(await store.checkpoint('remote-media'), 1);
      expect(
        (await notebooks.getNotebook(documentId))!.pages.first.imageBlocks,
        isEmpty,
      );

      buffer.stage(receipt: receipt, bytes: bytes);
      expect(
        await store.applyRemote(
          attached,
          serverSequence: 2,
          checkpointScope: 'remote-media',
          apply: () => activeProjector.apply(attached),
        ),
        isTrue,
      );
      buffer.clear();
      final image = (await notebooks.getNotebook(
        documentId,
      ))!.pages.first.imageBlocks.single;
      expect(image.id, 'remote-image');
      expect(image.position.dx, 11);
      expect(image.bytes, orderedEquals(bytes));
      expect(await store.checkpoint('remote-media'), 2);
      expect(await store.pending(), isEmpty);
    },
  );

  test(
    'remote image switch keeps old bytes until verified object.set',
    () async {
      final buffer = VerifiedEditorAssetBuffer();
      final bufferedProjector = EditorSqliteProjector(
        database,
        verifiedAssetBuffer: buffer,
      );
      final oldBytes = Uint8List.fromList([137, 80, 78, 71, 1, 1]);
      final newBytes = Uint8List.fromList([137, 80, 78, 71, 2, 2]);
      Map<String, dynamic> receipt(String id, Uint8List bytes) => {
        'assetId': id,
        'sha256': crypto.sha256.convert(bytes).toString(),
        'sizeBytes': bytes.length,
        'mediaType': 'image/png',
      };
      final oldReceipt = receipt('original', oldBytes);
      final newReceipt = receipt('replacement', newBytes);
      buffer.stage(receipt: oldReceipt, bytes: oldBytes);
      final initial = await store.writeLocalBatch(
        actorId: 'image-seed-actor',
        documentId: documentId,
        operations: [
          LocalOperationDraft(
            kind: OperationKind.objectCreate,
            pageId: pageId,
            objectId: 'remote-swapped-image',
            payload: const {
              'value': {
                'objectType': 'image',
                'assetId': 'original',
                'dx': 11.0,
                'dy': 13.0,
                'width': 120.0,
                'height': 80.0,
                'rotation': 0.0,
                'cropLeft': 0.0,
                'cropTop': 0.0,
                'cropRight': 1.0,
                'cropBottom': 1.0,
                'sortIndex': 0,
              },
            },
          ),
          LocalOperationDraft(
            kind: OperationKind.assetAttach,
            pageId: pageId,
            objectId: 'remote-swapped-image',
            payload: oldReceipt,
          ),
        ],
        apply: bufferedProjector.apply,
      );
      final newAttach = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'remote-image-swap',
        actorSeq: 1,
        logicalClock: 10,
        documentId: documentId,
        pageId: pageId,
        objectId: 'remote-swapped-image',
        kind: OperationKind.assetAttach,
        payload: newReceipt,
        dependencies: [initial.last.operationId],
      );
      final changed = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'remote-image-swap',
        actorSeq: 2,
        logicalClock: 11,
        documentId: documentId,
        pageId: pageId,
        objectId: 'remote-swapped-image',
        kind: OperationKind.objectSet,
        payload: const {
          'properties': {'assetId': 'replacement'},
        },
        dependencies: [newAttach.operationId],
      );
      final oldDetach = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'remote-image-swap',
        actorSeq: 3,
        logicalClock: 12,
        documentId: documentId,
        pageId: pageId,
        objectId: 'remote-swapped-image',
        kind: OperationKind.assetDetach,
        payload: const {'assetId': 'original'},
        dependencies: [changed.operationId],
      );
      buffer.stage(receipt: newReceipt, bytes: newBytes);
      expect(
        await store.applyRemote(
          newAttach,
          checkpointScope: 'replacement-feed',
          serverSequence: 1,
          apply: () => bufferedProjector.apply(newAttach),
        ),
        isTrue,
      );
      expect(
        (await notebooks.getNotebook(
          documentId,
        ))!.pages.single.imageBlocks.single.bytes,
        orderedEquals(oldBytes),
      );
      buffer.clear();
      await expectLater(
        store.applyRemote(
          changed,
          checkpointScope: 'replacement-feed',
          serverSequence: 2,
          apply: () => bufferedProjector.apply(changed),
        ),
        throwsStateError,
      );
      expect(await store.checkpoint('replacement-feed'), 1);
      expect(await store.operation(changed.operationId), isNull);
      expect(
        (await notebooks.getNotebook(
          documentId,
        ))!.pages.single.imageBlocks.single.bytes,
        orderedEquals(oldBytes),
      );
      buffer.stage(receipt: newReceipt, bytes: newBytes);
      expect(
        await store.applyRemote(
          changed,
          checkpointScope: 'replacement-feed',
          serverSequence: 2,
          apply: () => bufferedProjector.apply(changed),
        ),
        isTrue,
      );
      expect(
        await store.applyRemote(
          oldDetach,
          checkpointScope: 'replacement-feed',
          serverSequence: 3,
          apply: () => bufferedProjector.apply(oldDetach),
        ),
        isTrue,
      );
      expect(await store.checkpoint('replacement-feed'), 3);
      final stored = (await notebooks.getNotebook(
        documentId,
      ))!.pages.single.imageBlocks.single;
      expect(stored.bytes, orderedEquals(newBytes));
      expect(stored.id, 'remote-swapped-image');
      final refs = await database
          .customSelect(
            'SELECT asset_id FROM asset_references WHERE document_id = ?',
            variables: [Variable<String>(documentId)],
          )
          .get();
      expect(refs.map((row) => row.read<String>('asset_id')), ['replacement']);
    },
  );

  test('asset.detach cannot remove a still referenced Quill embed', () async {
    await write([
      LocalOperationDraft(
        kind: OperationKind.objectCreate,
        pageId: pageId,
        objectId: 'asset-text',
        payload: const {
          'value': {
            'objectType': 'text',
            'dx': 0.0,
            'dy': 0.0,
            'width': 200.0,
            'fontSize': 18.0,
            'rotation': 0.0,
            'colorValue': 0xFF000000,
            'sortIndex': 0,
          },
        },
      ),
    ]);
    await store.attachAssetReference(
      documentId: documentId,
      pageId: pageId,
      objectId: 'asset-text',
      assetId: 'attachment-one',
      storagePath: 'assets/attachment-one',
      checksumSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      byteLength: 24,
    );
    await database.customStatement(
      'UPDATE text_block_rows SET text = ?, delta_json = ? WHERE uid = ?',
      ['\uFFFC', '[{"insert":{"image":"asset:attachment-one"}}]', 'asset-text'],
    );
    Future<int> references() async {
      final rows = await database
          .customSelect(
            'SELECT asset_id FROM asset_references '
            'WHERE document_id = ? AND asset_id = ?',
            variables: [
              Variable<String>(documentId),
              const Variable<String>('attachment-one'),
            ],
          )
          .get();
      return rows.length;
    }

    final count = (await store.pending()).length;
    final detach = LocalOperationDraft(
      kind: OperationKind.assetDetach,
      pageId: pageId,
      objectId: 'asset-text',
      payload: const {'assetId': 'attachment-one'},
    );
    await expectLater(write([detach]), throwsStateError);
    expect(await references(), 1);
    expect(await store.pending(), hasLength(count));

    // Only the actual removal of the embed makes its reference detachable.
    await database.customStatement(
      'UPDATE text_block_rows SET text = ?, delta_json = ? WHERE uid = ?',
      ['', '[{"insert":"\\n"}]', 'asset-text'],
    );
    await write([detach]);
    expect(await references(), 0);
    expect((await store.pending()).last.kind, OperationKind.assetDetach);
    await expectLater(write([detach]), throwsStateError);
    expect(await references(), 0);
  });

  test(
    'active images cannot lose their only durable asset reference',
    () async {
      const imageId = 'active-image';
      await database.customStatement(
        'INSERT INTO image_block_rows '
        '(uid, page_uid, path, ocr_text, width, height, rotation, dx, dy, '
        'crop_left, crop_top, crop_right, crop_bottom, sort_index) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          imageId,
          pageId,
          '/tmp/asset.png',
          '',
          100.0,
          80.0,
          0.0,
          0.0,
          0.0,
          0.0,
          0.0,
          1.0,
          1.0,
          0,
        ],
      );
      await store.attachAssetReference(
        documentId: documentId,
        pageId: pageId,
        objectId: imageId,
        assetId: 'image-asset',
        storagePath: '/tmp/asset.png',
        checksumSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        byteLength: 10,
      );
      await expectLater(
        write([
          LocalOperationDraft(
            kind: OperationKind.assetDetach,
            pageId: pageId,
            objectId: imageId,
            payload: {'assetId': 'image-asset'},
          ),
        ]),
        throwsUnsupportedError,
      );
      expect(
        await database
            .customSelect(
              'SELECT asset_id FROM asset_references WHERE asset_id = ?',
              variables: [const Variable<String>('image-asset')],
            )
            .get(),
        hasLength(1),
      );
    },
  );

  test('verified image deletion is atomic and releases scoped asset', () async {
    const imageId = 'delete-verified-image';
    await database.customStatement(
      'INSERT INTO image_block_rows '
      '(uid, page_uid, path, ocr_text, width, height, rotation, dx, dy, '
      'crop_left, crop_top, crop_right, crop_bottom, sort_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        imageId,
        pageId,
        '/private/deletion.pdf',
        '',
        100.0,
        80.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        1.0,
        0,
      ],
    );
    final deletion = LocalOperationDraft(
      kind: OperationKind.objectDelete,
      pageId: pageId,
      objectId: imageId,
      payload: const {},
    );
    final pending = (await store.pending()).length;
    await expectLater(write([deletion]), throwsUnsupportedError);
    expect(await store.pending(), hasLength(pending));
    await store.attachAssetReference(
      documentId: documentId,
      pageId: pageId,
      objectId: imageId,
      assetId: 'deleted-asset',
      storagePath: '/private/deletion.pdf',
      checksumSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      byteLength: 24,
    );
    await write([deletion]);
    expect(
      await database
          .customSelect(
            'SELECT uid FROM image_block_rows WHERE uid = ?',
            variables: [const Variable<String>(imageId)],
          )
          .get(),
      isEmpty,
    );
    expect(
      await database
          .customSelect(
            'SELECT asset_id FROM asset_references WHERE asset_id = ?',
            variables: [const Variable<String>('deleted-asset')],
          )
          .get(),
      isEmpty,
    );
  });

  test(
    'Quill deletion rejects missing assets and releases verified ones',
    () async {
      const textId = 'deleted-text';
      await write([
        LocalOperationDraft(
          kind: OperationKind.objectCreate,
          pageId: pageId,
          objectId: textId,
          payload: const {
            'value': {
              'objectType': 'text',
              'dx': 0.0,
              'dy': 0.0,
              'width': 200.0,
              'fontSize': 18.0,
              'rotation': 0.0,
              'colorValue': 0xFF000000,
              'sortIndex': 0,
            },
          },
        ),
      ]);
      await database.customStatement(
        'UPDATE text_block_rows SET text = ?, delta_json = ? WHERE uid = ?',
        ['\uFFFC', '[{"insert":{"image":"asset:deleted-text-asset"}}]', textId],
      );
      final deletion = LocalOperationDraft(
        kind: OperationKind.objectDelete,
        pageId: pageId,
        objectId: textId,
        payload: const {},
      );
      final pending = (await store.pending()).length;
      await expectLater(write([deletion]), throwsUnsupportedError);
      expect(await store.pending(), hasLength(pending));
      await store.attachAssetReference(
        documentId: documentId,
        pageId: pageId,
        objectId: textId,
        assetId: 'deleted-text-asset',
        storagePath: '/private/embedded',
        checksumSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        byteLength: 24,
      );
      await write([deletion]);
      expect(
        await database
            .customSelect(
              'SELECT uid FROM text_block_rows WHERE uid = ?',
              variables: [const Variable<String>(textId)],
            )
            .get(),
        isEmpty,
      );
      expect(
        await database
            .customSelect(
              'SELECT asset_id FROM asset_references WHERE asset_id = ?',
              variables: [const Variable<String>('deleted-text-asset')],
            )
            .get(),
        isEmpty,
      );
    },
  );

  test('v2 page deletion cannot orphan a stored image asset', () async {
    const target = 'asset-page';
    await write([
      const LocalOperationDraft(
        kind: OperationKind.pageCreate,
        objectId: target,
        payload: {
          'value': {'title': 'Assets', 'isBookmarked': false},
        },
      ),
    ]);
    await database.customStatement(
      'INSERT INTO image_block_rows '
      '(uid, page_uid, path, ocr_text, width, height, rotation, dx, dy, '
      'crop_left, crop_top, crop_right, crop_bottom, sort_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'media-one',
        target,
        '/private/asset.pdf',
        '',
        100.0,
        80.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        1.0,
        0,
      ],
    );
    final queued = await store.pending();
    await expectLater(
      write([
        const LocalOperationDraft(
          kind: OperationKind.pageDelete,
          objectId: target,
          payload: {},
        ),
      ]),
      throwsUnsupportedError,
    );
    expect(await store.pending(), hasLength(queued.length));
    expect(
      await database
          .customSelect(
            'SELECT uid FROM page_rows WHERE uid = ?',
            variables: [const Variable<String>(target)],
          )
          .get(),
      hasLength(1),
    );
    expect(
      await database
          .customSelect(
            'SELECT uid FROM image_block_rows WHERE uid = ?',
            variables: [const Variable<String>('media-one')],
          )
          .get(),
      hasLength(1),
    );
  });

  test('v2 page deletion preserves durable asset reference rows', () async {
    const target = 'reference-page';
    await write([
      const LocalOperationDraft(
        kind: OperationKind.pageCreate,
        objectId: target,
        payload: {
          'value': {'title': 'Attached', 'isBookmarked': false},
        },
      ),
    ]);
    await store.attachAssetReference(
      documentId: documentId,
      pageId: target,
      objectId: 'owner-object',
      assetId: 'verified-one',
      storagePath: '/private/verified-one',
      checksumSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      byteLength: 12,
    );
    final queued = await store.pending();
    await expectLater(
      write([
        const LocalOperationDraft(
          kind: OperationKind.pageDelete,
          objectId: target,
          payload: {},
        ),
      ]),
      throwsUnsupportedError,
    );
    expect(await store.pending(), hasLength(queued.length));
    expect(
      await database
          .customSelect(
            'SELECT asset_id FROM asset_references '
            'WHERE document_id = ?',
            variables: [Variable<String>(documentId)],
          )
          .get(),
      hasLength(1),
    );
  });

  test('v2 page deletion cannot orphan a Quill embed', () async {
    const target = 'embed-page';
    await write([
      const LocalOperationDraft(
        kind: OperationKind.pageCreate,
        objectId: target,
        payload: {
          'value': {'title': 'Embeds', 'isBookmarked': false},
        },
      ),
    ]);
    await database.customStatement(
      'INSERT INTO text_block_rows '
      '(uid, page_uid, text, delta_json, font_size, color_value, '
      'width, rotation, dx, dy, sort_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'quill-one',
        target,
        '\uFFFC',
        '[{"insert":{"image":"asset:asset-one"}}]',
        18.0,
        0xFF000000,
        120.0,
        0.0,
        0.0,
        0.0,
        0,
      ],
    );
    final queued = await store.pending();
    await expectLater(
      write([
        const LocalOperationDraft(
          kind: OperationKind.pageDelete,
          objectId: target,
          payload: {},
        ),
      ]),
      throwsUnsupportedError,
    );
    expect(await store.pending(), hasLength(queued.length));
    expect(
      await database
          .customSelect(
            'SELECT uid FROM text_block_rows WHERE uid = ?',
            variables: [const Variable<String>('quill-one')],
          )
          .get(),
      hasLength(1),
    );
  });

  test(
    'page deletion releases only fully linked media in one commit',
    () async {
      const page = 'delete-linked-page';
      const media = 'page-linked-image';
      await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: page,
          payload: {
            'value': {'title': 'Linked', 'isBookmarked': false},
          },
        ),
      ]);
      await database.customStatement(
        'INSERT INTO image_block_rows '
        '(uid, page_uid, path, ocr_text, width, height, rotation, dx, dy, '
        'crop_left, crop_top, crop_right, crop_bottom, sort_index) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          media,
          page,
          '/private/linked.pdf',
          '',
          100.0,
          80.0,
          0.0,
          0.0,
          0.0,
          0.0,
          0.0,
          1.0,
          1.0,
          0,
        ],
      );
      await store.attachAssetReference(
        documentId: documentId,
        pageId: page,
        objectId: media,
        assetId: 'linked-asset',
        storagePath: '/private/linked.pdf',
        checksumSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        byteLength: 24,
      );
      await write([
        const LocalOperationDraft(
          kind: OperationKind.pageDelete,
          objectId: page,
          payload: {},
        ),
      ]);
      expect(
        await database
            .customSelect(
              'SELECT uid FROM page_rows WHERE uid = ?',
              variables: [const Variable<String>(page)],
            )
            .get(),
        isEmpty,
      );
      expect(
        await database
            .customSelect(
              'SELECT uid FROM image_block_rows WHERE uid = ?',
              variables: [const Variable<String>(media)],
            )
            .get(),
        isEmpty,
      );
      expect(
        await database
            .customSelect(
              'SELECT asset_id FROM asset_references WHERE asset_id = ?',
              variables: [const Variable<String>('linked-asset')],
            )
            .get(),
        isEmpty,
      );
    },
  );

  test(
    'page deletion keeps a shared asset reference owned by another page',
    () async {
      const target = 'shared-asset-page';
      const sharedAsset = 'shared-asset';
      const targetImage = 'shared-target-image';
      const siblingImage = 'shared-sibling-image';
      await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: target,
          payload: {
            'value': {'title': 'Shared asset', 'isBookmarked': false},
          },
        ),
      ]);

      Future<void> insertImage(String id, String ownerPage) {
        return database.customStatement(
          'INSERT INTO image_block_rows '
          '(uid, page_uid, path, ocr_text, width, height, rotation, dx, dy, '
          'crop_left, crop_top, crop_right, crop_bottom, sort_index) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            id,
            ownerPage,
            '/private/$id.png',
            '',
            100.0,
            80.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
            1.0,
            0,
          ],
        );
      }

      await insertImage(targetImage, target);
      await insertImage(siblingImage, pageId);
      const checksum =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      await store.attachAssetReference(
        documentId: documentId,
        pageId: target,
        objectId: targetImage,
        assetId: sharedAsset,
        storagePath: '/private/shared.png',
        checksumSha256: checksum,
        byteLength: 24,
      );
      await store.attachAssetReference(
        documentId: documentId,
        pageId: pageId,
        objectId: siblingImage,
        assetId: sharedAsset,
        storagePath: '/private/shared.png',
        checksumSha256: checksum,
        byteLength: 24,
      );

      await write([
        const LocalOperationDraft(
          kind: OperationKind.pageDelete,
          objectId: target,
          payload: {},
        ),
      ]);

      final remaining = await database
          .customSelect(
            'SELECT object_id FROM asset_references '
            'WHERE document_id = ? AND asset_id = ?',
            variables: [
              Variable<String>(documentId),
              const Variable<String>(sharedAsset),
            ],
          )
          .get();
      expect(remaining.map((row) => row.read<String>('object_id')), [
        'page:${jsonEncode([pageId, siblingImage])}',
      ]);
      expect(
        await database
            .customSelect(
              'SELECT uid FROM image_block_rows WHERE uid = ?',
              variables: [const Variable<String>(targetImage)],
            )
            .get(),
        isEmpty,
      );
    },
  );

  test('the last page cannot be removed through v2', () async {
    await expectLater(
      write([
        LocalOperationDraft(
          kind: OperationKind.pageDelete,
          objectId: pageId,
          payload: const {},
        ),
      ]),
      throwsStateError,
    );
    expect((await notebooks.getNotebook(documentId))?.pages, hasLength(1));
    expect(await store.pending(), isEmpty);
  });

  test('committed ink and outbox survive restarting SQLite', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nanotateczki-v2-projector-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/notes.sqlite');
    final first = NotesDatabase(NativeDatabase(file));
    final firstRepository = NotebookRepository(first);
    final firstStore = OperationStore(first);
    final notebook = await firstRepository.createNotebook();
    final operation = await firstStore.writeLocal(
      actorId: 'restart-actor',
      documentId: notebook.uid,
      pageId: notebook.pages.single.id,
      objectId: 'restart-ink',
      kind: OperationKind.strokeCreate,
      payload: {'value': _stroke()},
      apply: EditorSqliteProjector(first).apply,
    );
    await first.close();

    final reopened = NotesDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final recovered = await NotebookRepository(
      reopened,
    ).getNotebook(notebook.uid);
    expect(recovered?.pages.single.inkStrokes.single.id, 'restart-ink');
    final recoveredStore = OperationStore(reopened);
    expect(
      (await recoveredStore.pending()).single.operationId,
      operation.operationId,
    );
    expect(
      (await recoveredStore.operation(operation.operationId))?.actorSeq,
      1,
    );
  });
  test('invalid Quill embed MIME rolls back journal and asset BLOB', () async {
    final buffer = VerifiedEditorAssetBuffer();
    final checkedProjector = EditorSqliteProjector(
      database,
      verifiedAssetBuffer: buffer,
    );
    final bytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
    const assetId = 'mixed-mime-asset';
    final receipt = <String, dynamic>{
      'assetId': assetId,
      'sha256': crypto.sha256.convert(bytes).toString(),
      'sizeBytes': bytes.length,
      'mediaType': 'image/png',
    };
    buffer.stage(receipt: receipt, bytes: bytes);
    await expectLater(
      store.writeLocalBatch(
        actorId: 'malformed-quill',
        documentId: documentId,
        operations: [
          LocalOperationDraft(
            kind: OperationKind.objectCreate,
            pageId: pageId,
            objectId: 'text-mixed-mime',
            payload: const {
              'value': {
                'objectType': 'text',
                'fontSize': 18.0,
                'colorValue': 0xFF123456,
                'width': 200.0,
                'rotation': 0.0,
                'dx': 0.0,
                'dy': 0.0,
                'sortIndex': 0,
              },
            },
          ),
          LocalOperationDraft(
            kind: OperationKind.assetAttach,
            pageId: pageId,
            objectId: 'text-mixed-mime',
            payload: receipt,
          ),
          LocalOperationDraft(
            kind: OperationKind.textInsert,
            pageId: pageId,
            objectId: 'text-mixed-mime',
            payload: {
              'afterAtomId': null,
              'atoms': [
                {
                  'id': const Uuid().v4(),
                  'text': '\uFFFC',
                  'embed': {'pdf': 'asset:$assetId'},
                },
              ],
            },
          ),
        ],
        apply: checkedProjector.apply,
      ),
      throwsStateError,
    );
    expect(await store.pending(), isEmpty);
    final texts = await database
        .customSelect(
          'SELECT uid FROM text_block_rows WHERE page_uid = ?',
          variables: [Variable<String>(pageId)],
        )
        .get();
    expect(texts, isEmpty);
    final references = await database
        .customSelect(
          'SELECT asset_id FROM asset_references WHERE document_id = ?',
          variables: [Variable<String>(documentId)],
        )
        .get();
    expect(references, isEmpty);
    final blobs = await database
        .customSelect('SELECT checksum_sha256 FROM operation_asset_bytes')
        .get();
    expect(blobs, isEmpty);
  });

  Future<void> checkCorruptQuillDeletion({
    required bool deletePage,
    bool formatOnly = false,
  }) async {
    const extraPage = 'corrupt-embed-page';
    final targetPage = deletePage ? extraPage : pageId;
    final objectId = deletePage ? 'corrupt-embed-page-text' : 'corrupt-text';
    final assetId = deletePage ? 'corrupt-page-asset' : 'corrupt-text-asset';
    if (deletePage) {
      await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: extraPage,
          payload: {
            'value': {'title': 'Corrupt media', 'isBookmarked': false},
          },
        ),
      ]);
    }

    final bytes = Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      1,
      2,
      3,
      4,
    ]);
    final receipt = <String, dynamic>{
      'assetId': assetId,
      'sha256': crypto.sha256.convert(bytes).toString(),
      'sizeBytes': bytes.length,
      'mediaType': 'image/png',
    };
    final buffer = VerifiedEditorAssetBuffer();
    buffer.stage(receipt: receipt, bytes: bytes);
    final checkedProjector = EditorSqliteProjector(
      database,
      verifiedAssetBuffer: buffer,
    );

    final embedAtomId = const Uuid().v4();
    await store.writeLocalBatch(
      actorId: 'valid-quill-setup',
      documentId: documentId,
      operations: [
        LocalOperationDraft(
          kind: OperationKind.objectCreate,
          pageId: targetPage,
          objectId: objectId,
          payload: const {
            'value': {
              'objectType': 'text',
              'fontSize': 18.0,
              'colorValue': 0xFF123456,
              'width': 200.0,
              'rotation': 0.0,
              'dx': 0.0,
              'dy': 0.0,
              'sortIndex': 0,
            },
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.assetAttach,
          pageId: targetPage,
          objectId: objectId,
          payload: receipt,
        ),
        LocalOperationDraft(
          kind: OperationKind.textInsert,
          pageId: targetPage,
          objectId: objectId,
          payload: {
            'afterAtomId': null,
            'atoms': [
              {
                'id': embedAtomId,
                'text': '\uFFFC',
                'embed': {'image': 'asset:$assetId'},
              },
              {'id': const Uuid().v4(), 'text': '\n'},
            ],
          },
        ),
      ],
      apply: checkedProjector.apply,
    );

    final deletion = formatOnly
        ? LocalOperationDraft(
            kind: OperationKind.textFormat,
            pageId: targetPage,
            objectId: objectId,
            payload: {
              'atomIds': [embedAtomId],
              'attributes': {'bold': true},
            },
          )
        : LocalOperationDraft(
            kind: deletePage
                ? OperationKind.pageDelete
                : OperationKind.objectDelete,
            pageId: deletePage ? null : targetPage,
            objectId: deletePage ? targetPage : objectId,
            payload: const {},
          );
    final pendingBefore = await store.pending();
    await database.customStatement(
      'UPDATE operation_asset_bytes SET bytes = ? WHERE checksum_sha256 = ?',
      [
        Uint8List.fromList(List<int>.filled(bytes.length, 0)),
        receipt['sha256'],
      ],
    );

    await expectLater(write([deletion]), throwsFormatException);
    expect(await store.pending(), hasLength(pendingBefore.length));
    expect(
      await database
          .customSelect(
            'SELECT uid FROM text_block_rows WHERE uid = ?',
            variables: [Variable<String>(objectId)],
          )
          .get(),
      hasLength(1),
    );
    expect(
      await database
          .customSelect(
            'SELECT asset_id FROM asset_references '
            'WHERE document_id = ? AND asset_id = ?',
            variables: [
              Variable<String>(documentId),
              Variable<String>(assetId),
            ],
          )
          .get(),
      hasLength(1),
    );

    await database.customStatement(
      'UPDATE operation_asset_bytes SET bytes = ? WHERE checksum_sha256 = ?',
      [bytes, receipt['sha256']],
    );
    await write([deletion]);
    if (formatOnly) {
      final block = (await notebooks.getNotebook(
        documentId,
      ))!.pages.single.textBlocks.single;
      expect(block.deltaJson, contains('"bold":true'));
      expect(
        await database
            .customSelect(
              'SELECT asset_id FROM asset_references '
              'WHERE document_id = ? AND asset_id = ?',
              variables: [
                Variable<String>(documentId),
                Variable<String>(assetId),
              ],
            )
            .get(),
        hasLength(1),
      );
      expect(await store.pending(), hasLength(pendingBefore.length + 1));
      return;
    }
    expect(
      await database
          .customSelect(
            'SELECT uid FROM text_block_rows WHERE uid = ?',
            variables: [Variable<String>(objectId)],
          )
          .get(),
      isEmpty,
    );
    expect(
      await database
          .customSelect(
            'SELECT asset_id FROM asset_references '
            'WHERE document_id = ? AND asset_id = ?',
            variables: [
              Variable<String>(documentId),
              Variable<String>(assetId),
            ],
          )
          .get(),
      isEmpty,
    );
    expect(await store.pending(), hasLength(pendingBefore.length + 1));
    if (deletePage) {
      expect(
        await database
            .customSelect(
              'SELECT uid FROM page_rows WHERE uid = ?',
              variables: [Variable<String>(targetPage)],
            )
            .get(),
        isEmpty,
      );
    }
  }

  test('object.delete refuses corrupt durable Quill BLOB', () async {
    await checkCorruptQuillDeletion(deletePage: false);
  });

  test('page.delete refuses corrupt durable Quill BLOB', () async {
    await checkCorruptQuillDeletion(deletePage: true);
  });

  test('text.format refuses corrupt durable Quill BLOB', () async {
    await checkCorruptQuillDeletion(deletePage: false, formatOnly: true);
  });
  for (final moveFirst in [false, true]) {
    test('concurrent move and style preserve original journal, '
        'moveFirst=$moveFirst', () async {
      const destination = 'rebase-destination';
      const objectId = 'rebase-stroke';
      final setup = await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: destination,
          payload: {
            'value': {'title': 'Destination', 'isBookmarked': false},
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: objectId,
          payload: {'value': _stroke()},
        ),
      ]);
      final move = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'move-remote',
        actorSeq: 1,
        logicalClock: 50,
        documentId: documentId,
        pageId: pageId,
        objectId: objectId,
        kind: OperationKind.objectMove,
        payload: const {'toPageId': destination, 'sortIndex': 4},
        dependencies: [setup.last.operationId],
      );
      final style = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'style-remote',
        actorSeq: 1,
        logicalClock: 51,
        documentId: documentId,
        pageId: pageId,
        objectId: objectId,
        kind: OperationKind.objectSet,
        payload: const {
          'properties': {'colorValue': 0xFF778899},
        },
        dependencies: [setup.last.operationId],
      );
      final delivered = moveFirst ? [move, style] : [style, move];
      for (var index = 0; index < delivered.length; index++) {
        final item = delivered[index];
        expect(
          await store.applyRemote(
            item,
            serverSequence: index + 1,
            checkpointScope: 'rebase-style',
            apply: () => projector.apply(item),
          ),
          isTrue,
        );
      }
      final notebook = (await notebooks.getNotebook(documentId))!;
      expect(notebook.pages.first.inkStrokes, isEmpty);
      final stroke = notebook.pages.last.inkStrokes.single;
      expect(stroke.id, objectId);
      expect(stroke.color.toARGB32(), 0xFF778899);
      expect(await store.checkpoint('rebase-style'), 2);
      expect((await store.operation(style.operationId))!.pageId, pageId);
      expect((await store.pending(includeDeferred: true)).map(
        (item) => item.operationId,
      ), setup.map((item) => item.operationId));
      expect(
        await store.applyRemote(
          delivered.last,
          serverSequence: 2,
          apply: () => projector.apply(delivered.last),
        ),
        isFalse,
      );
    });
  }

  for (final moveFirst in [false, true]) {
    test('concurrent move and object deletion never resurrect a UID, '
        'moveFirst=$moveFirst', () async {
      const destination = 'delete-move-destination';
      const objectId = 'deleted-moved-stroke';
      final setup = await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: destination,
          payload: {
            'value': {'title': 'Destination', 'isBookmarked': false},
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.strokeCreate,
          pageId: pageId,
          objectId: objectId,
          payload: {'value': _stroke()},
        ),
      ]);
      OperationEnvelope event(
        OperationKind kind,
        String actor,
        int clock,
        Map<String, dynamic> payload,
      ) => OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: actor,
        actorSeq: 1,
        logicalClock: clock,
        documentId: documentId,
        pageId: pageId,
        objectId: objectId,
        kind: kind,
        payload: payload,
        dependencies: [setup.last.operationId],
      );
      final move = event(
        OperationKind.objectMove,
        'move-device',
        40,
        const {'toPageId': destination, 'sortIndex': 1},
      );
      final delete = event(
        OperationKind.objectDelete,
        'delete-device',
        41,
        const {},
      );
      final events = moveFirst ? [move, delete] : [delete, move];
      for (var index = 0; index < events.length; index++) {
        final item = events[index];
        await store.applyRemote(
          item,
          serverSequence: index + 1,
          apply: () => projector.apply(item),
        );
      }
      final notebook = (await notebooks.getNotebook(documentId))!;
      expect(
        notebook.pages.expand((page) => page.inkStrokes)
            .where((stroke) => stroke.id == objectId),
        isEmpty,
      );
      expect(
        await store.wasObjectDeleted(
          documentId: documentId,
          objectId: objectId,
        ),
        isTrue,
      );
    });
  }


  for (final moveFirst in [false, true]) {
    test('image replacement after a concurrent move preserves assets, '
        'moveFirst=$moveFirst', () async {
      const destination = 'concurrent-media-destination';
      const objectId = 'concurrent-media-image';
      final buffer = VerifiedEditorAssetBuffer();
      final backed = EditorSqliteProjector(
        database,
        verifiedAssetBuffer: buffer,
      );
      final firstBytes = Uint8List.fromList([137, 80, 78, 71, 1, 2]);
      final nextBytes = Uint8List.fromList([137, 80, 78, 71, 3, 4]);
      Map<String, dynamic> receipt(String id, Uint8List bytes) => {
        'assetId': id,
        'sha256': crypto.sha256.convert(bytes).toString(),
        'sizeBytes': bytes.length,
        'mediaType': 'image/png',
      };
      final first = receipt('media-original', firstBytes);
      final replacement = receipt('media-replacement', nextBytes);
      buffer.stage(receipt: first, bytes: firstBytes);
      buffer.stage(receipt: replacement, bytes: nextBytes);
      final setup = await store.writeLocalBatch(
        actorId: 'media-setup',
        documentId: documentId,
        operations: [
          const LocalOperationDraft(
            kind: OperationKind.pageCreate,
            objectId: destination,
            payload: {
              'value': {'title': 'Images', 'isBookmarked': false},
            },
          ),
          LocalOperationDraft(
            kind: OperationKind.objectCreate,
            pageId: pageId,
            objectId: objectId,
            payload: const {
              'value': {
                'objectType': 'image',
                'assetId': 'media-original',
                'dx': 1.0,
                'dy': 2.0,
                'width': 100.0,
                'height': 80.0,
                'rotation': 0.0,
                'cropLeft': 0.0,
                'cropTop': 0.0,
                'cropRight': 1.0,
                'cropBottom': 1.0,
                'sortIndex': 0,
              },
            },
          ),
          LocalOperationDraft(
            kind: OperationKind.assetAttach,
            pageId: pageId,
            objectId: objectId,
            payload: first,
          ),
        ],
        apply: backed.apply,
      );
      OperationEnvelope envelope(
        OperationKind kind,
        String actor,
        int actorSeq,
        int clock,
        Map<String, dynamic> payload,
        List<String> deps,
      ) => OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: actor,
        actorSeq: actorSeq,
        logicalClock: clock,
        documentId: documentId,
        pageId: pageId,
        objectId: objectId,
        kind: kind,
        payload: payload,
        dependencies: deps,
      );
      final move = envelope(
        OperationKind.objectMove,
        'media-mover',
        1,
        49,
        const {'toPageId': destination, 'sortIndex': 4},
        [setup.last.operationId],
      );
      final attach = envelope(
        OperationKind.assetAttach,
        'media-editor',
        1,
        50,
        replacement,
        [setup.last.operationId],
      );
      final switchAsset = envelope(
        OperationKind.objectSet,
        'media-editor',
        2,
        51,
        const {
          'properties': {'assetId': 'media-replacement'},
        },
        [attach.operationId],
      );
      final detach = envelope(
        OperationKind.assetDetach,
        'media-editor',
        3,
        52,
        const {'assetId': 'media-original'},
        [switchAsset.operationId],
      );
      final operations = moveFirst
          ? [move, attach, switchAsset, detach]
          : [attach, switchAsset, detach, move];
      for (var index = 0; index < operations.length; index++) {
        final event = operations[index];
        await store.applyRemote(
          event,
          serverSequence: index + 1,
          checkpointScope: 'media-rebase',
          apply: () => backed.apply(event),
        );
      }
      final notebook = (await notebooks.getNotebook(documentId))!;
      expect(notebook.pages.first.imageBlocks, isEmpty);
      expect(notebook.pages.last.imageBlocks, hasLength(1));
      final image = notebook.pages.last.imageBlocks.single;
      expect(image.id, objectId);
      expect(image.bytes, orderedEquals(nextBytes));
      final refs = await database.customSelect(
        'SELECT object_id, asset_id FROM asset_references '
        'WHERE document_id = ?',
        variables: [Variable<String>(documentId)],
      ).get();
      expect(refs, hasLength(1));
      expect(refs.single.read<String>('asset_id'), 'media-replacement');
      expect(
        refs.single.read<String>('object_id'),
        'page:${jsonEncode([destination, objectId])}',
      );
      expect((await store.operation(attach.operationId))!.pageId, pageId);
      expect((await store.operation(switchAsset.operationId))!.pageId, pageId);
      expect(await store.checkpoint('media-rebase'), 4);
      expect(await store.pending(includeDeferred: true), hasLength(3));
    });
  }

  for (final moveFirst in [false, true]) {
    test('Quill atom tombstones and formatting survive a cross-page move, '
        'moveFirst=$moveFirst', () async {
      const destination = 'quill-rebased-destination';
      const objectId = 'quill-rebased-text';
      const atomId = '11111111-1111-4111-8111-111111111111';
      final setup = await write([
        const LocalOperationDraft(
          kind: OperationKind.pageCreate,
          objectId: destination,
          payload: {
            'value': {'title': 'Quill', 'isBookmarked': false},
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.objectCreate,
          pageId: pageId,
          objectId: objectId,
          payload: const {
            'value': {
              'objectType': 'text',
              'dx': 0.0,
              'dy': 0.0,
              'width': 200.0,
              'fontSize': 18.0,
              'rotation': 0.0,
              'colorValue': 0xFF000000,
              'sortIndex': 0,
            },
          },
        ),
        LocalOperationDraft(
          kind: OperationKind.textInsert,
          pageId: pageId,
          objectId: objectId,
          payload: const {
            'afterAtomId': null,
            'atoms': [
              {'id': atomId, 'text': 'A'},
            ],
          },
        ),
      ]);
      OperationEnvelope envelope(
        OperationKind kind,
        String actor,
        int clock,
        Map<String, dynamic> payload,
      ) => OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: actor,
        actorSeq: 1,
        logicalClock: clock,
        documentId: documentId,
        pageId: pageId,
        objectId: objectId,
        kind: kind,
        payload: payload,
        dependencies: [setup.last.operationId],
      );
      final move = envelope(
        OperationKind.objectMove,
        'quill-mover',
        40,
        const {'toPageId': destination, 'sortIndex': 1},
      );
      final format = envelope(
        OperationKind.textFormat,
        'quill-formatter',
        41,
        const {
          'atomIds': [atomId],
          'attributes': {'bold': true},
        },
      );
      final deletion = envelope(
        OperationKind.textDelete,
        'quill-deleter',
        42,
        const {
          'atomIds': [atomId],
        },
      );
      final operations = moveFirst
          ? [move, format, deletion]
          : [deletion, format, move];
      for (var index = 0; index < operations.length; index++) {
        final event = operations[index];
        await store.applyRemote(
          event,
          serverSequence: index + 1,
          checkpointScope: 'quill-move-rebase',
          apply: () => projector.apply(event),
        );
      }
      final notebook = (await notebooks.getNotebook(documentId))!;
      expect(notebook.pages.first.textBlocks, isEmpty);
      expect(notebook.pages.last.textBlocks, hasLength(1));
      expect(notebook.pages.last.textBlocks.single.id, objectId);
      expect(notebook.pages.last.textBlocks.single.text, isEmpty);
      final atoms = await store.textAtoms(
        documentId: documentId,
        pageId: destination,
        objectId: objectId,
      );
      expect((atoms[atomId] as Map)['deleted'], isTrue);
      expect((atoms[atomId] as Map)['attributes'], {'bold': true});
      expect((await store.operation(format.operationId))!.pageId, pageId);
      expect(await store.checkpoint('quill-move-rebase'), 3);
      expect(await store.pending(includeDeferred: true),
          hasLength(setup.length));
    });
  }

  test('late edit on relocated deleted UID is a durable no-op', () async {
    const destination = 'deleted-rebased-destination';
    const objectId = 'deleted-rebased-object';
    final setup = await write([
      const LocalOperationDraft(
        kind: OperationKind.pageCreate,
        objectId: destination,
        payload: {
          'value': {'title': 'Destination', 'isBookmarked': false},
        },
      ),
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: objectId,
        payload: {'value': _stroke()},
      ),
    ]);
    OperationEnvelope event(
      OperationKind kind,
      String actor,
      int clock,
      String source,
      Map<String, dynamic> payload,
    ) => OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: actor,
      actorSeq: 1,
      logicalClock: clock,
      documentId: documentId,
      pageId: source,
      objectId: objectId,
      kind: kind,
      payload: payload,
      dependencies: [setup.last.operationId],
    );
    final move = event(
      OperationKind.objectMove,
      'mover',
      40,
      pageId,
      const {'toPageId': destination, 'sortIndex': 1},
    );
    final delete = event(
      OperationKind.objectDelete,
      'deleter',
      41,
      pageId,
      const {},
    );
    final stale = event(
      OperationKind.objectSet,
      'late-writer',
      42,
      destination,
      const {
        'properties': {'colorValue': 0xFFAABBCC},
      },
    );
    for (final operation in [move, delete, stale]) {
      expect(
        await store.applyRemote(
          operation,
          serverSequence: 1 + [move, delete, stale].indexOf(operation),
          checkpointScope: 'tombstoned-move',
          apply: () => projector.apply(operation),
        ),
        isTrue,
      );
    }
    expect(await store.operation(stale.operationId), isNotNull);
    expect(await store.checkpoint('tombstoned-move'), 3);
    final notebook = (await notebooks.getNotebook(documentId))!;
    expect(
      notebook.pages.expand((page) => page.inkStrokes)
          .where((stroke) => stroke.id == objectId),
      isEmpty,
    );
  });

  test('late object.delete after page.delete records a safe tombstone',
      () async {
    const destination = 'page-remaining-after-delete';
    const objectId = 'deleted-with-source-page';
    final setup = await write([
      const LocalOperationDraft(
        kind: OperationKind.pageCreate,
        objectId: destination,
        payload: {
          'value': {'title': 'Remaining', 'isBookmarked': false},
        },
      ),
      LocalOperationDraft(
        kind: OperationKind.strokeCreate,
        pageId: pageId,
        objectId: objectId,
        payload: {'value': _stroke()},
      ),
    ]);
    final removed = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'delete-page-actor',
      actorSeq: 1,
      logicalClock: 50,
      documentId: documentId,
      objectId: pageId,
      kind: OperationKind.pageDelete,
      payload: const {},
      dependencies: [setup.last.operationId],
    );
    final late = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: 'delete-object-actor',
      actorSeq: 1,
      logicalClock: 51,
      documentId: documentId,
      pageId: pageId,
      objectId: objectId,
      kind: OperationKind.objectDelete,
      payload: const {},
      dependencies: [setup.last.operationId],
    );
    await store.applyRemote(
      removed,
      serverSequence: 1,
      checkpointScope: 'deleted-page-object',
      apply: () => projector.apply(removed),
    );
    expect(
      await store.applyRemote(
        late,
        serverSequence: 2,
        checkpointScope: 'deleted-page-object',
        apply: () => projector.apply(late),
      ),
      isTrue,
    );
    expect(await store.checkpoint('deleted-page-object'), 2);
    expect(
      await store.wasObjectDeleted(
        documentId: documentId,
        objectId: objectId,
      ),
      isTrue,
    );
    final notebook = (await notebooks.getNotebook(documentId))!;
    expect(notebook.pages, hasLength(1));
    expect(notebook.pages.single.inkStrokes, isEmpty);
  });
}
