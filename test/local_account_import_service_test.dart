import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/core/storage/active_storage_namespace.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/local_account_import_service.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/library_v2_operation_service.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:program/features/editor/state/editor_v2_operation_writer.dart';
import 'package:program/data/sync/local_import_plan.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/planner/state/study_planner_controller.dart';

Notebook _note() => Notebook(
  uid: 'local-document',
  title: 'Physics',
  kind: NotebookKind.notebook,
  folder: 'School',
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
  pages: [
    NotePage(
      id: 'local-page',
      title: 'Page',
      textBlocks: [],
      imageBlocks: [],
      inkStrokes: [],
      isBookmarked: false,
    ),
  ],
);

class _OfflineGateway implements OperationGateway {
  @override
  Future<List<OperationReceipt>> send(
    List<OperationEnvelope> operations,
  ) async => throw StateError('Offline');

  @override
  Future<OperationFeedPage> readAfter(int cursor) async =>
      throw StateError('Offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NotesDatabase localDb;
  late NotesDatabase accountDb;
  late NotebookRepository local;
  late NotebookRepository account;
  late StudyPlannerController planner;
  late Map<String, String> files;
  late Map<String, String> plannerFiles;
  late LocalAccountImportService service;
  var libraryReloads = 0;
  var active = true;

  setUp(() async {
    localDb = NotesDatabase(NativeDatabase.memory());
    accountDb = NotesDatabase(NativeDatabase.memory());
    local = NotebookRepository(localDb);
    account = NotebookRepository(accountDb);
    files = {};
    plannerFiles = {};
    libraryReloads = 0;
    active = true;
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async {
      files[key] = value;
    };
    planner = StudyPlannerController(
      autoTick: false,
      read: (key) async => plannerFiles[key],
      write: (key, value) async {
        plannerFiles[key] = value;
      },
    );
    await planner.load();
    await local.saveNotebook(_note());
    service = LocalAccountImportService(
      accountId: 'account-a',
      repository: account,
      planner: planner,
      isCurrentAccount: () => active,
      onLibraryChanged: () async {
        libraryReloads++;
      },
    );
  });

  tearDown(() async {
    await planner.flush();
    planner.dispose();
    await localDb.close();
    await accountDb.close();
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
    ActiveStorageNamespace.activate(StorageNamespace.local());
  });

  test('copies notebooks, folders, tasks, study sessions once', () async {
    final session = StudySession(
      id: 'source-study',
      title: 'Revision',
      scheduledAt: DateTime.utc(2026, 11, 12),
      minutes: 45,
      repeat: StudyRepeat.weekly,
      status: StudyStatus.completed,
    );
    final localLibrary = jsonEncode({
      'folders': ['School'],
      'covers': {
        'School': {'shape': 'star'},
      },
      'plannerTasks': {
        'local-document': [
          {'id': 'source-task', 'title': 'Chapter 1', 'completed': true},
        ],
      },
    });
    final localPlanner = jsonEncode({
      'version': 2,
      'sessions': [session.toJson()],
    });
    files['library_folders.json'] = jsonEncode({
      'folders': ['School'],
      'covers': {
        'School': {'shape': 'heart'},
      },
      'recentCoverColors': [123],
    });

    expect(
      await service.runWithSource(
        sourceRepository: local,
        localLibraryText: localLibrary,
        localPlannerText: localPlanner,
      ),
      1,
    );
    expect(
      await service.runWithSource(
        sourceRepository: local,
        localLibraryText: localLibrary,
        localPlannerText: localPlanner,
      ),
      0,
    );
    final importedId = importedLocalUid(
      'account-a',
      'document',
      'local-document',
    );
    final copied = await account.getNotebook(importedId);
    expect(copied, isNotNull);
    expect(copied!.pages.single.id, isNot('local-page'));
    expect(await local.getNotebook('local-document'), isNotNull);
    expect((await local.fetchNotebooks()).single.uid, 'local-document');
    final metadata = jsonDecode(files['library_folders.json']!);
    expect(metadata['covers']['School']['shape'], 'heart');
    expect(metadata['recentCoverColors'], [123]);
    expect(metadata['plannerTasks'][importedId], hasLength(1));
    expect(planner.sessions, hasLength(1));
    expect(planner.sessions.single.repeat, StudyRepeat.weekly);
    expect(planner.sessions.single.status, StudyStatus.completed);
    expect(libraryReloads, 1);
    expect(
      (jsonDecode(files[LocalAccountImportService.checkpointKey]!)
          as Map<String, dynamic>)['state'],
      'complete',
    );
  });

  test(
    'resumes after a post-document failure without duplicating UID',
    () async {
      var failOnce = true;
      final interrupted = LocalAccountImportService(
        accountId: 'account-a',
        repository: account,
        planner: planner,
        isCurrentAccount: () => active,
        onLibraryChanged: () async {
          if (failOnce) {
            failOnce = false;
            throw StateError('Interrupted after document commit');
          }
        },
      );
      await expectLater(
        interrupted.runWithSource(
          sourceRepository: local,
          localLibraryText: '{"folders":["School"]}',
          localPlannerText: null,
        ),
        throwsStateError,
      );
      expect(
        (jsonDecode(files[LocalAccountImportService.checkpointKey]!)
            as Map<String, dynamic>)['state'],
        'pending',
      );
      expect(await account.fetchNotebooks(), hasLength(1));
      expect(
        await interrupted.runWithSource(
          sourceRepository: local,
          localLibraryText: '{"folders":["School"]}',
          localPlannerText: null,
        ),
        0,
      );
      expect(await account.fetchNotebooks(), hasLength(1));
      expect(await local.fetchNotebooks(), hasLength(1));
    },
  );

  test('v2 Local import persists planner folders and tasks as operations',
      () async {
    ActiveStorageNamespace.activate(StorageNamespace.account('account-a'));
    final sourcePlanner = await local.createPlanner(folder: 'School');
    final importedTaskId = importedLocalUid(
      'account-a', 'task:${sourcePlanner.uid}', 'task-local-1',
    );
    final store = OperationStore(
      accountDb,
      checkpointScope: 'account:account-a',
    );
    final projector = EditorSqliteProjector(accountDb);
    final engine = SyncEngine(
      store: store,
      gateway: _OfflineGateway(),
      actorId: 'import-v2-actor',
      checkpointScope: 'account:account-a',
      enableRealtime: false,
      applyRemote: (op, pending) => projector.apply(op),
    );
    addTearDown(engine.stop);
    await account.enableAccountOperations(
      EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
        onCommitted: account.reportOperationCommit,
      ),
    );
    final journal = LibraryV2OperationService(
      engine: engine,
      accountId: 'account-a',
    );
    final importer = LocalAccountImportService(
      accountId: 'account-a',
      repository: account,
      planner: planner,
      libraryV2: journal,
      isCurrentAccount: () => active,
      onLibraryChanged: () async {},
    );
    final localLibrary = jsonEncode({
      'folders': ['School', 'School/Lab'],
      'covers': {
        'School': {'shape': 'star'},
      },
      'plannerTasks': {
        sourcePlanner.uid: [
          {'id': 'task-local-1', 'title': 'Lab review', 'completed': true},
        ],
      },
    });
    expect(
      await importer.runWithSource(
        sourceRepository: local,
        localLibraryText: localLibrary,
        localPlannerText: null,
      ),
      2,
    );
    final projected = await journal.snapshot();
    expect(projected.folderIdsByPath.keys, contains('School/Lab'));
    final plannerUid = importedLocalUid(
      'account-a', 'document', sourcePlanner.uid,
    );
    expect(projected.value['plannerTasks'][plannerUid], hasLength(1));
    expect(await account.getNotebook(plannerUid), isNotNull);
    expect((await store.pending()).map((op) => op.kind),
        contains(OperationKind.taskCreate));

    await journal.deleteTask(importedTaskId);
    files.remove(LocalAccountImportService.checkpointKey);
    await importer.runWithSource(
      sourceRepository: local,
      localLibraryText: localLibrary,
      localPlannerText: null,
    );
    expect(await journal.wasTaskDeleted(importedTaskId), isTrue);
    expect((await journal.snapshot()).value['plannerTasks'], isEmpty);
  });

  test(
    'account switch fence retains pending import and Local source',
    () async {
      active = false;
      await expectLater(
        service.runWithSource(
          sourceRepository: local,
          localLibraryText: null,
          localPlannerText: null,
        ),
        throwsStateError,
      );
      expect(await account.fetchNotebooks(), isEmpty);
      expect(await local.fetchNotebooks(), hasLength(1));
      active = true;
      expect(
        await service.runWithSource(
          sourceRepository: local,
          localLibraryText: null,
          localPlannerText: null,
        ),
        1,
      );
    },
  );
}
