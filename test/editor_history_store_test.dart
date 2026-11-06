import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_history_checkpoint.dart';
import 'package:program/data/sync/editor_history_store.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:uuid/uuid.dart';

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('Offline');
  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('Offline');
}

class _Session {
  _Session(File file) {
    database = NotesDatabase(NativeDatabase(file));
    repository = NotebookRepository(database);
    store = OperationStore(database);
    history = EditorHistoryStore(store);
    projector = EditorSqliteProjector(database);
    engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'history-test',
      checkpointScope: 'history-test',
      enableRealtime: false,
      applyRemote: (op, _) => projector.apply(op),
    );
    writer = EditorV2OperationWriter(syncEngine: engine, projector: projector);
  }
  late final NotesDatabase database;
  late final NotebookRepository repository;
  late final OperationStore store;
  late final EditorHistoryStore history;
  late final EditorSqliteProjector projector;
  late final SyncEngine engine;
  late final EditorV2OperationWriter writer;
  Future<Notebook> create() async {
    await repository.enableAccountOperations(writer);
    return repository.createNotebook();
  }

  Future<void> close() async {
    await engine.stop();
    await database.close();
  }
}

Notebook addStroke(Notebook notebook, String id) => notebook.copyWith(
  pages: [
    notebook.pages.single.copyWith(
      inkStrokes: [
        ...notebook.pages.single.inkStrokes,
        InkStroke(
          id: id,
          color: const Color(0xFF123456),
          width: 2,
          tool: DrawingTool.pen,
          points: [const InkPoint(dx: 1, dy: 2, pressure: 0.5)],
        ),
      ],
    ),
  ],
);
StoredEditorGesture entry(
  String documentId,
  String operationId,
  int before,
  int after,
) => StoredEditorGesture(
  before: {'uid': documentId, 'strokes': before},
  after: {'uid': documentId, 'strokes': after},
  operationId: operationId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  late _Session session;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nn-editor-history-');
    file = File('${directory.path}/notes.sqlite');
    session = _Session(file);
  });
  tearDown(() async {
    await session.close();
    await directory.delete(recursive: true);
  });

  test(
    'gesture, owner checkpoint, actor sequence and outbox survive restart',
    () async {
      final notebook = await session.create();
      late EditorHistoryCheckpoint checkpoint;
      final committed = await session.writer.writeNotebookChange(
        before: notebook,
        after: addStroke(notebook, 'first'),
        onCommittedInTransaction: (ops) async {
          expect(() => ops.clear(), throwsUnsupportedError);
          checkpoint = EditorHistoryCheckpoint(
            documentId: notebook.uid,
            ownerId: ops.last.actorId,
            headOperationId: ops.last.operationId,
            undo: [entry(notebook.uid, ops.last.operationId, 0, 1)],
            redo: [],
          );
          await session.history.save(checkpoint);
        },
      );
      final pending = (await session.store.pending())
          .map((op) => op.operationId)
          .toList();
      await session.close();
      session = _Session(file);
      final restored = await session.history.load(
        documentId: notebook.uid,
        ownerId: checkpoint.ownerId,
      );
      expect(restored!.encode(), checkpoint.encode());
      expect(restored.undo.single.operationId, committed.last.operationId);
      expect(
        (await session.repository.getNotebook(
          notebook.uid,
        ))!.pages.single.inkStrokes.single.id,
        'first',
      );
      expect(
        (await session.store.pending()).map((op) => op.operationId),
        pending,
      );
      expect(
        await session.history.load(
          documentId: notebook.uid,
          ownerId: 'other-device',
        ),
        isNull,
      );
      expect(
        await session.history.load(
          documentId: 'other-document',
          ownerId: checkpoint.ownerId,
        ),
        isNull,
      );
    },
  );

  test(
    'history write failure rolls back projection, outbox and actor sequence',
    () async {
      final notebook = await session.create();
      final before = await session.store.pending();
      await session.database.customStatement(
        "CREATE TRIGGER fail_history BEFORE INSERT ON editor_history BEGIN SELECT RAISE(ABORT, 'injected history failure'); END",
      );
      Future<List<OperationEnvelope>> write() =>
          session.writer.writeNotebookChange(
            before: notebook,
            after: addStroke(addStroke(notebook, 'retry'), 'retry-2'),
            onCommittedInTransaction: (ops) async {
              expect(ops, hasLength(2));
              expect(
                (await session.repository.getNotebook(
                  notebook.uid,
                ))!.pages.single.inkStrokes,
                hasLength(2),
              );
              await session.history.save(
                EditorHistoryCheckpoint(
                  documentId: notebook.uid,
                  ownerId: ops.last.actorId,
                  headOperationId: ops.last.operationId,
                  undo: [entry(notebook.uid, ops.last.operationId, 0, 2)],
                  redo: [],
                ),
              );
            },
          );
      await expectLater(write(), throwsA(isA<Exception>()));
      expect(
        (await session.repository.getNotebook(
          notebook.uid,
        ))!.pages.single.inkStrokes,
        isEmpty,
      );
      expect(
        (await session.store.pending()).map((op) => op.operationId),
        before.map((op) => op.operationId),
      );
      expect(
        await session.database
            .customSelect('SELECT * FROM editor_history')
            .get(),
        isEmpty,
      );
      await session.database.customStatement('DROP TRIGGER fail_history');
      final committed = await write();
      expect(committed.last.actorSeq, before.last.actorSeq + 2);
    },
  );

  test(
    'failure after saving history restores the previous checkpoint too',
    () async {
      final notebook = await session.create();
      late EditorHistoryCheckpoint first;
      await session.writer.writeNotebookChange(
        before: notebook,
        after: addStroke(notebook, 'first'),
        onCommittedInTransaction: (ops) async {
          first = EditorHistoryCheckpoint(
            documentId: notebook.uid,
            ownerId: ops.last.actorId,
            headOperationId: ops.last.operationId,
            undo: [entry(notebook.uid, ops.last.operationId, 0, 1)],
            redo: [],
          );
          await session.history.save(first);
        },
      );
      final original = (await session.repository.getNotebook(notebook.uid))!;
      final before = await session.store.pending();
      await expectLater(
        session.writer.writeNotebookChange(
          before: original,
          after: addStroke(original, 'second'),
          onCommittedInTransaction: (ops) async {
            await session.history.save(
              EditorHistoryCheckpoint(
                documentId: notebook.uid,
                ownerId: ops.last.actorId,
                headOperationId: ops.last.operationId,
                undo: [
                  ...first.undo,
                  entry(notebook.uid, ops.last.operationId, 1, 2),
                ],
                redo: [],
              ),
            );
            throw StateError('Simulated failure after checkpoint update');
          },
        ),
        throwsStateError,
      );
      expect(
        (await session.history.load(
          documentId: notebook.uid,
          ownerId: first.ownerId,
        ))!.encode(),
        first.encode(),
      );
      expect(
        (await session.store.pending()).map((op) => op.operationId),
        before.map((op) => op.operationId),
      );
      expect(
        (await session.repository.getNotebook(
          notebook.uid,
        ))!.pages.single.inkStrokes,
        hasLength(1),
      );
    },
  );

  test(
    'finalizing an autosaved gesture can update history without a new operation',
    () async {
      final notebook = await session.create();
      final changed = addStroke(notebook, 'first');
      final ops = await session.writer.writeNotebookChange(
        before: notebook,
        after: changed,
      );
      final pending = await session.store.pending();
      final committed = await session.writer.writeNotebookChange(
        before: changed,
        after: changed,
        onCommittedInTransaction: (empty) async {
          expect(empty, isEmpty);
          await session.history.save(
            EditorHistoryCheckpoint(
              documentId: notebook.uid,
              ownerId: ops.last.actorId,
              headOperationId: ops.last.operationId,
              undo: [],
              redo: [entry(notebook.uid, ops.last.operationId, 0, 1)],
            ),
          );
        },
      );
      expect(committed, isEmpty);
      expect(
        (await session.history.load(
          documentId: notebook.uid,
          ownerId: ops.last.actorId,
        ))!.redo,
        hasLength(1),
      );
      expect(
        (await session.store.pending()).map((op) => op.operationId),
        pending.map((op) => op.operationId),
      );
    },
  );

  test(
    'fitting history in the gesture transaction preserves content and outbox',
    () async {
      final notebook = await session.create();
      late EditorHistoryCheckpoint saved;
      final committed = await session.writer.writeNotebookChange(
        before: notebook,
        after: addStroke(notebook, 'kept-content'),
        onCommittedInTransaction: (ops) async {
          final oversized = EditorHistoryCheckpoint(
            documentId: notebook.uid,
            ownerId: ops.last.actorId,
            headOperationId: ops.last.operationId,
            undo: [
              StoredEditorGesture(
                before: {'uid': notebook.uid, 'padding': 'x' * 4096},
                after: {'uid': notebook.uid, 'padding': 'y' * 4096},
                operationId: ops.last.operationId,
              ),
            ],
            redo: [],
          );
          saved = oversized.fitToByteBudget(byteLimit: 512);
          await session.history.save(saved);
        },
      );
      final loaded = (await session.history.load(
        documentId: notebook.uid,
        ownerId: saved.ownerId,
      ))!;
      expect(loaded.undo, isEmpty);
      expect(loaded.redo, isEmpty);
      expect(loaded.headOperationId, committed.last.operationId);
      expect(
        (await session.repository.getNotebook(
          notebook.uid,
        ))!.pages.single.inkStrokes.single.id,
        'kept-content',
      );
      expect(
        (await session.store.pending()).map((op) => op.operationId),
        contains(committed.last.operationId),
      );
    },
  );

  test(
    'owner mismatch and missing operations cannot replace valid history',
    () async {
      final notebook = await session.create();
      final ops = await session.writer.writeNotebookChange(
        before: notebook,
        after: addStroke(notebook, 'first'),
      );
      final valid = EditorHistoryCheckpoint(
        documentId: notebook.uid,
        ownerId: ops.last.actorId,
        headOperationId: ops.last.operationId,
        undo: [entry(notebook.uid, ops.last.operationId, 0, 1)],
        redo: [],
      );
      await session.history.save(valid);
      final foreign = await session.create();
      final foreignOperation = (await session.store.pending()).lastWhere(
        (op) => op.documentId == foreign.uid,
      );
      for (final invalid in [
        EditorHistoryCheckpoint(
          documentId: notebook.uid,
          ownerId: 'other-device',
          headOperationId: ops.last.operationId,
          undo: valid.undo,
          redo: [],
        ),
        EditorHistoryCheckpoint(
          documentId: notebook.uid,
          ownerId: 'other-device',
          headOperationId: ops.last.operationId,
          undo: [],
          redo: [],
        ),
        EditorHistoryCheckpoint(
          documentId: notebook.uid,
          ownerId: ops.last.actorId,
          headOperationId: ops.last.operationId,
          undo: [entry(notebook.uid, foreignOperation.operationId, 0, 1)],
          redo: [],
        ),
        EditorHistoryCheckpoint(
          documentId: notebook.uid,
          ownerId: ops.last.actorId,
          headOperationId: ops.last.operationId,
          undo: [entry(notebook.uid, const Uuid().v4(), 0, 1)],
          redo: [],
        ),
      ]) {
        await expectLater(session.history.save(invalid), throwsStateError);
      }
      expect(
        (await session.history.load(
          documentId: notebook.uid,
          ownerId: valid.ownerId,
        ))!.encode(),
        valid.encode(),
      );
      await session.database.customStatement(
        'UPDATE editor_history SET payload_json = ?',
        ['{}'],
      );
      await expectLater(
        session.history.load(documentId: notebook.uid, ownerId: valid.ownerId),
        throwsFormatException,
      );
      expect(
        (await session.repository.getNotebook(
          notebook.uid,
        ))!.pages.single.inkStrokes,
        hasLength(1),
      );
    },
  );

  test(
    'a new committed head invalidates old history without deleting it',
    () async {
      final notebook = await session.create();
      final changed = addStroke(notebook, 'first');
      final ops = await session.writer.writeNotebookChange(
        before: notebook,
        after: changed,
      );
      final saved = EditorHistoryCheckpoint(
        documentId: notebook.uid,
        ownerId: ops.last.actorId,
        headOperationId: ops.last.operationId,
        undo: [entry(notebook.uid, ops.last.operationId, 0, 1)],
        redo: [],
      );
      await session.history.save(saved);
      await session.writer.writeNotebookChange(
        before: changed,
        after: addStroke(changed, 'second'),
      );
      expect(
        await session.history.load(
          documentId: notebook.uid,
          ownerId: saved.ownerId,
        ),
        isNull,
      );
      await expectLater(session.history.save(saved), throwsStateError);
      final row = await session.database
          .customSelect('SELECT payload_json FROM editor_history')
          .getSingle();
      expect(
        jsonDecode(row.read<String>('payload_json')),
        jsonDecode(saved.encode()),
      );
    },
  );

  test(
    'remote operations invalidate local history and cannot become owned Undo entries',
    () async {
      final notebook = await session.create();
      final ops = await session.writer.writeNotebookChange(
        before: notebook,
        after: addStroke(notebook, 'first'),
      );
      final saved = EditorHistoryCheckpoint(
        documentId: notebook.uid,
        ownerId: ops.last.actorId,
        headOperationId: ops.last.operationId,
        undo: [entry(notebook.uid, ops.last.operationId, 0, 1)],
        redo: [],
      );
      await session.history.save(saved);
      final remote = OperationEnvelope(
        operationId: const Uuid().v4(),
        actorId: 'remote-peer',
        actorSeq: 1,
        documentId: notebook.uid,
        pageId: notebook.pages.single.id,
        objectId: 'remote-stroke',
        kind: OperationKind.strokeCreate,
        logicalClock: ops.last.logicalClock + 1,
        dependencies: [ops.last.operationId],
        payload: {
          'value': {
            'objectType': 'stroke',
            'colorValue': 0xFF123456,
            'width': 2,
            'toolIndex': 0,
            'sortIndex': 1,
            'points': [
              [1, 2, 0.5],
            ],
          },
        },
      );
      await session.store.applyRemote(
        remote,
        serverSequence: 100,
        apply: () => session.projector.apply(remote),
      );
      expect(
        await session.history.load(
          documentId: notebook.uid,
          ownerId: saved.ownerId,
        ),
        isNull,
      );
      await expectLater(
        session.history.save(
          EditorHistoryCheckpoint(
            documentId: notebook.uid,
            ownerId: remote.actorId,
            headOperationId: remote.operationId,
            undo: [entry(notebook.uid, remote.operationId, 1, 2)],
            redo: [],
          ),
        ),
        throwsStateError,
      );
      expect(
        (await session.repository.getNotebook(
          notebook.uid,
        ))!.pages.single.inkStrokes,
        hasLength(2),
      );
    },
  );

  test(
    'document tombstone prevents recovery even with a matching new head',
    () async {
      final notebook = await session.create();
      final deleted = await session.writer.writeDeleteNotebook(
        documentId: notebook.uid,
      );
      await expectLater(
        session.history.save(
          EditorHistoryCheckpoint(
            documentId: notebook.uid,
            ownerId: deleted.last.actorId,
            headOperationId: deleted.last.operationId,
            undo: [],
            redo: [],
          ),
        ),
        throwsStateError,
      );
      expect(await session.repository.getNotebook(notebook.uid), isNull);
      expect(
        await session.database
            .customSelect('SELECT * FROM editor_history')
            .get(),
        isEmpty,
      );
    },
  );

  test(
    'v7 migration keeps journal and content while creating an empty history store',
    () async {
      final notebook = await session.create();
      final before = await session.store.pending();
      await session.database.customStatement('DROP TABLE editor_history');
      await session.database.customStatement('PRAGMA user_version = 7');
      await session.close();
      session = _Session(file);
      expect(await session.repository.getNotebook(notebook.uid), isNotNull);
      expect(session.database.schemaVersion, 8);
      expect(
        (await session.store.pending()).map((op) => op.operationId),
        before.map((op) => op.operationId),
      );
      expect(
        await session.database
            .customSelect('SELECT * FROM editor_history')
            .get(),
        isEmpty,
      );
    },
  );
}
