import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
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
