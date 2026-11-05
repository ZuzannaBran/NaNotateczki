import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull;
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
    final rows = await database.customSelect(
      'SELECT uid, points_json, color_value, sort_index '
      'FROM ink_stroke_rows WHERE page_uid = ?',
      variables: [Variable<String>(pageId)],
    ).get();
    return [for (final row in rows) row.data];
  }

  test('legacy eraser migration cannot rewrite a v2 ink document',
      () async {
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
      final rows = await database.customSelect(
        'SELECT uid FROM ink_stroke_rows WHERE page_uid = ? ORDER BY uid',
        variables: [Variable<String>(pageId)],
      ).get();
      return [
        for (final row in rows) row.read<String>('uid'),
      ];
    }
    final beforeRead = await persistedIds();
    expect(beforeRead, contains('legacy-eraser'));
    final freshRepository = NotebookRepository(database);
    expect(await freshRepository.getNotebook(documentId), isNotNull);
    expect(await persistedIds(), beforeRead);
    expect(await store.pending(), hasLength(1));
  });

  test('a fresh repository cannot overwrite committed v2 history',
      () async {
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
      reopenedRepository.saveNotebookPages(
        existing,
        {pageId},
      ),
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
      (await reopenedRepository.getNotebook(documentId))!
          .pages.first.inkStrokes.single.id,
      'protected-ink',
    );

    // A different document without operational history remains writable.
    final sibling = await reopenedRepository.createNotebook();
    expect(await reopenedRepository.saveNotebook(sibling), isTrue);
  });

  test('rapid v2 commits never invent future notebook timestamps',
      () async {
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
    expect(
      (await store.pending()).map((operation) => operation.actorSeq),
      [1, 2],
    );
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
    final afterRollback =
        (await notebooks.getNotebook(documentId))!.updatedAt;
    expect(afterRollback, second);
    expect(await store.pending(), hasLength(previousOutbox.length));
  });

  test('ink create, transform and delete persist as atomic operations',
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
    expect((await store.pending()).single.operationId,
        added.single.operationId);

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
    expect(
      after.pages.single.inkStrokes.single.color.toARGB32(),
      0xFFABCDEF,
    );

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
  });

  test('invalid second operation rolls back projection and actor sequence',
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
  });

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
            {'id': atomA, 'text': 'H', 'attributes': {'bold': true}},
            {'id': atomB, 'text': 'i', 'attributes': {'bold': true}},
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
    final changed = (await notebooks.getNotebook(documentId))!
        .pages.single.textBlocks.single;
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

  test('concurrent ink fields converge despite reverse delivery',
      () async {
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
      properties: {
        'colorValue': 0xFF00AA00,
        'width': 4.0,
      },
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
    final persisted = (await notebooks.getNotebook(documentId))!
        .pages.first.inkStrokes.single;
    expect(persisted.color.toARGB32(), 0xFFAA0000);
    expect(persisted.width, 4.0);
    expect(await store.checkpoint('ink-fields'), 2);
  });

  test('page metadata uses field rank rather than receipt order',
      () async {
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

  test('equal clocks resolve object colors by actor identity',
      () async {
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
      (await notebooks.getNotebook(documentId))!
          .pages.first.inkStrokes.single.color.toARGB32(),
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
      expect(
        result.pages[2].inkStrokes.single.id,
        'concurrent-move-ink',
      );
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

  test('object.move preserves the stroke identity across notebook pages',
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
        payload: const {
          'toPageId': destination,
          'sortIndex': 2,
        },
      ),
    ]);
    final notebook = (await notebooks.getNotebook(documentId))!;
    expect(notebook.pages.first.inkStrokes, isEmpty);
    expect(notebook.pages.last.inkStrokes.single.id, 'moved-stroke');
    expect(
      (await database.customSelect(
        'SELECT sort_index FROM ink_stroke_rows '
        'WHERE uid = ? AND page_uid = ?',
        variables: [
          const Variable<String>('moved-stroke'),
          const Variable<String>(destination),
        ],
      ).get()).single.read<int>('sort_index'),
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
          payload: const {
            'toPageId': destination,
            'sortIndex': 2,
          },
        ),
      ]),
      throwsUnsupportedError,
    );
    expect(
      (await notebooks.getNotebook(documentId))!
          .pages.last.inkStrokes.single.id,
      'moved-stroke',
    );
  });

  test('ambiguous cross-layer identity cannot delete either object',
      () async {
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
      ['duplicate', pageId, '', null, 18.0, 0xFF000000,
        100.0, 0.0, 0.0, 0.0, 0],
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
      (await database.customSelect(
        'SELECT uid FROM text_block_rows WHERE uid = ?',
        variables: [const Variable<String>('duplicate')],
      ).get()),
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

  test('image move relocates the durable asset reference atomically',
      () async {
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
        imageId, pageId, '', '', bytes, 'png', 'image/png',
        100.0, 80.0, 0.0, 10.0, 20.0, 0.0, 0.0, 1.0, 1.0, 0,
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

    await store.attachAssetReference(
      documentId: documentId,
      pageId: pageId,
      objectId: imageId,
      assetId: 'media-asset-one',
      storagePath: 'assets/media-asset-one',
      checksumSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      byteLength: 4,
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
    final references = await database.customSelect(
      'SELECT object_id FROM asset_references '
      'WHERE document_id = ? AND asset_id = ?',
      variables: [
        Variable<String>(documentId),
        const Variable<String>('media-asset-one'),
      ],
    ).get();
    expect(references, hasLength(1));
    expect(
      references.single.read<String>('object_id'),
      'page:${jsonEncode([target, imageId])}',
    );
    expect(
      await store.isTombstoned(
        documentId,
        'object',
        imageId,
        pageId: pageId,
      ),
      isFalse,
    );
  });

  test('remote image stays invisible until verified asset materialization',
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
    final image =
        (await notebooks.getNotebook(documentId))!.pages.first.imageBlocks.single;
    expect(image.id, 'remote-image');
    expect(image.position.dx, 11);
    expect(image.bytes, orderedEquals(bytes));
    expect(await store.checkpoint('remote-media'), 2);
    expect(await store.pending(), isEmpty);
  });

  test('asset.detach cannot remove a still referenced Quill embed',
      () async {
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
      [
        '\uFFFC',
        '[{"insert":{"image":"asset:attachment-one"}}]',
        'asset-text',
      ],
    );
    Future<int> references() async {
      final rows = await database.customSelect(
        'SELECT asset_id FROM asset_references '
        'WHERE document_id = ? AND asset_id = ?',
        variables: [
          Variable<String>(documentId),
          const Variable<String>('attachment-one'),
        ],
      ).get();
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

  test('active images cannot lose their only durable asset reference',
      () async {
    const imageId = 'active-image';
    await database.customStatement(
      'INSERT INTO image_block_rows '
      '(uid, page_uid, path, ocr_text, width, height, rotation, dx, dy, '
      'crop_left, crop_top, crop_right, crop_bottom, sort_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        imageId, pageId, '/tmp/asset.png', '',
        100.0, 80.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0,
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
        const LocalOperationDraft(
          kind: OperationKind.assetDetach,
          pageId: pageId,
          objectId: imageId,
          payload: {'assetId': 'image-asset'},
        ),
      ]),
      throwsUnsupportedError,
    );
    expect(
      await database.customSelect(
        'SELECT asset_id FROM asset_references WHERE asset_id = ?',
        variables: [const Variable<String>('image-asset')],
      ).get(),
      hasLength(1),
    );
  });

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
        'media-one', target, '/private/asset.pdf', '',
        100.0, 80.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0,
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
      await database.customSelect(
        'SELECT uid FROM page_rows WHERE uid = ?',
        variables: [const Variable<String>(target)],
      ).get(),
      hasLength(1),
    );
    expect(
      await database.customSelect(
        'SELECT uid FROM image_block_rows WHERE uid = ?',
        variables: [const Variable<String>('media-one')],
      ).get(),
      hasLength(1),
    );
  });

  test('v2 page deletion preserves durable asset reference rows',
      () async {
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
      await database.customSelect(
        'SELECT asset_id FROM asset_references '
        'WHERE document_id = ?',
        variables: [Variable<String>(documentId)],
      ).get(),
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
        'quill-one', target, '\uFFFC',
        '[{"insert":{"image":"asset:asset-one"}}]',
        18.0, 0xFF000000, 120.0, 0.0, 0.0, 0.0, 0,
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
      await database.customSelect(
        'SELECT uid FROM text_block_rows WHERE uid = ?',
        variables: [const Variable<String>('quill-one')],
      ).get(),
      hasLength(1),
    );
  });

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
    final recovered = await NotebookRepository(reopened).getNotebook(
      notebook.uid,
    );
    expect(
      recovered?.pages.single.inkStrokes.single.id,
      'restart-ink',
    );
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
}
