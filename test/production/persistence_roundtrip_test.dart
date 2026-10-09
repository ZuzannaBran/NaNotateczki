import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/text_block.dart';

const _quillDelta =
    '[{"insert":"Production","attributes":{"bold":true}},'
    '{"insert":" roundtrip\\n"}]';

InkStroke _ink(String id) => InkStroke(
  id: id,
  points: const [
    InkPoint(dx: 1.5, dy: 2.5, pressure: 0.3),
    InkPoint(dx: 28, dy: 80, pressure: 0.95),
  ],
  color: const Color(0xFF127ACF),
  width: 3.25,
  tool: DrawingTool.highlighter,
);

Notebook _fixture({required String uid}) {
  final now = DateTime.utc(2026, 10, 8, 10);
  return Notebook(
    uid: uid,
    title: 'Release fixture',
    folder: 'Production QA',
    kind: NotebookKind.notebook,
    createdAt: now,
    updatedAt: now,
    pages: [
      NotePage(
        id: '$uid-page-1',
        title: 'First',
        isBookmarked: true,
        textBlocks: [
          TextBlock(
            id: '$uid-text',
            text: 'Production roundtrip',
            deltaJson: _quillDelta,
            position: const Offset(32.5, 88.25),
            fontSize: 18.5,
            color: const Color(0xFF102030),
            width: 230.75,
            rotation: 0,
          ),
        ],
        imageBlocks: [
          ImageBlock(
            id: '$uid-image',
            path: '',
            ocrText: 'Recognized text',
            bytes: Uint8List.fromList([1, 3, 5, 7, 11, 13]),
            imageExt: 'png',
            imageMime: 'image/png',
            position: const Offset(100.5, 124.25),
            width: 220,
            height: 160,
            cropLeft: 0.15,
            cropTop: 0.2,
            cropRight: 0.9,
            cropBottom: 0.85,
          ),
        ],
        inkStrokes: [_ink('$uid-stroke')],
      ),
      NotePage(
        id: '$uid-page-2',
        title: 'Second',
        isBookmarked: false,
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: [_ink('$uid-stroke-2')],
      ),
    ],
  );
}

void _verifyContent(Notebook notebook, {required String uid}) {
  expect(notebook.uid, uid);
  expect(notebook.kind, NotebookKind.notebook);
  expect(notebook.pages, hasLength(2));
  final first = notebook.pages.first;
  expect(first.id, '$uid-page-1');
  expect(first.isBookmarked, isTrue);
  expect(first.textBlocks.single.deltaJson, _quillDelta);
  expect(first.textBlocks.single.position, const Offset(32.5, 88.25));
  expect(first.textBlocks.single.fontSize, 18.5);
  expect(first.imageBlocks.single.position, const Offset(100.5, 124.25));
  expect(first.imageBlocks.single.cropLeft, 0.15);
  expect(first.imageBlocks.single.cropTop, 0.2);
  expect(first.imageBlocks.single.cropRight, 0.9);
  expect(first.imageBlocks.single.cropBottom, 0.85);
  expect(first.imageBlocks.single.ocrText, 'Recognized text');
  final image = first.imageBlocks.single;
  if (image.path.isEmpty) {
    expect(image.bytes, [1, 3, 5, 7, 11, 13]);
  } else {
    expect(image.bytes, isNull);
    expect(File(image.path).readAsBytesSync(), [1, 3, 5, 7, 11, 13]);
  }
  expect(first.inkStrokes.single.points.last.pressure, 0.95);
  expect(first.inkStrokes.single.tool, DrawingTool.highlighter);
  expect(notebook.pages.last.inkStrokes.single.id, '$uid-stroke-2');
}

NotebookRepository _repository(NotesDatabase database) {
  return NotebookRepository(
    database,
    dataIntegrityIncidentHandler: (_, _, _) async {},
  );
}

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documentsDirectory;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'nanotateczki-persistence-',
    );
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(documentsDirectory.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  test('board and notebook toolbar placements persist after reload', () async {
    final original = AppPreferencesController();
    expect(original.boardToolbarPlacement, ToolbarPlacement.top);
    expect(original.notebookToolbarPlacement, ToolbarPlacement.top);
    await original.setBoardToolbarPlacement(ToolbarPlacement.left);
    await original.setNotebookToolbarPlacement(ToolbarPlacement.right);
    original.dispose();

    final loaded = AppPreferencesController();
    await loaded.load();
    expect(loaded.boardToolbarPlacement, ToolbarPlacement.left);
    expect(loaded.notebookToolbarPlacement, ToolbarPlacement.right);
    await loaded.setBoardToolbarPlacement(ToolbarPlacement.right);
    await loaded.setNotebookToolbarPlacement(ToolbarPlacement.left);
    expect(loaded.notebookToolbarPlacement, ToolbarPlacement.right);
    loaded.dispose();

    final restored = AppPreferencesController();
    await restored.load();
    expect(restored.boardToolbarPlacement, ToolbarPlacement.right);
    expect(restored.notebookToolbarPlacement, ToolbarPlacement.right);
    restored.dispose();
  });

  test(
    'SQLite read-after-write preserves rich content and binary media',
    () async {
      final db = NotesDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = _repository(db);
      final notebook = _fixture(uid: 'roundtrip');
      expect(await repository.saveNotebook(notebook), isTrue);

      final persisted = await repository.getNotebook(notebook.uid);
      expect(persisted, isNotNull);
      _verifyContent(persisted!, uid: notebook.uid);
    },
  );

  test(
    'portable archive preserves two pages, styles, crop and folders',
    () async {
      final db = NotesDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = _repository(db);
      final notebook = _fixture(uid: 'portable');

      final payload = repository.encodePortableBackup(
        [notebook],
        folders: ['Production QA', 'Empty QA folder'],
      );
      final decoded = repository.decodePortableBackup(payload);

      expect(decoded.notebooks, hasLength(1));
      expect(decoded.folders, contains('Empty QA folder'));
      _verifyContent(decoded.notebooks.single, uid: notebook.uid);
    },
  );

  test('incremental dirty-page save keeps the other page unchanged', () async {
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = _repository(db);
    final before = _fixture(uid: 'dirty-page');
    expect(await repository.saveNotebook(before), isTrue);

    final updated = before.copyWith(
      updatedAt: before.updatedAt.add(const Duration(minutes: 1)),
      pages: [
        before.pages.first.copyWith(title: 'Edited first page'),
        before.pages.last.copyWith(title: 'Should not be persisted'),
      ],
    );
    expect(
      await repository.saveNotebookPages(updated, {before.pages.first.id}),
      isTrue,
    );

    final persisted = await repository.getNotebook(before.uid);
    expect(persisted?.pages.first.title, 'Edited first page');
    expect(persisted?.pages.last.title, 'Second');
    expect(persisted?.pages.last.inkStrokes.single.id, 'dirty-page-stroke-2');
  });

  test(
    'concurrent independent saves settle without losing either document',
    () async {
      final db = NotesDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = _repository(db);
      final first = _fixture(uid: 'concurrent-a');
      final second = _fixture(uid: 'concurrent-b');

      final outcome = await Future.wait([
        repository.saveNotebook(first),
        repository.saveNotebook(second),
      ]);
      expect(outcome, [true, true]);
      await repository.waitForPendingSaves();
      expect(repository.hasPendingSaves, isFalse);

      final saved = await repository.fetchNotebooks();
      expect(saved.map((item) => item.uid).toSet(), {first.uid, second.uid});
      _verifyContent(
        saved.firstWhere((item) => item.uid == first.uid),
        uid: first.uid,
      );
      _verifyContent(
        saved.firstWhere((item) => item.uid == second.uid),
        uid: second.uid,
      );
    },
  );

  test(
    'incremental backup to a fresh database restores rich content',
    () async {
      final source = _fixture(uid: 'restore-target');
      final db = NotesDatabase(NativeDatabase.memory());
      final backup = LocalBackupService(
        _repository(db),
        documentsDirectory: () async => documentsDirectory,
      );

      try {
        final report = await backup.snapshot([source]);
        expect(report.changedCount, 1);
        expect((await backup.readLatest()), hasLength(1));
      } finally {
        await backup.dispose();
        await db.close();
      }

      final secondDb = NotesDatabase(NativeDatabase.memory());
      addTearDown(secondDb.close);
      final restore = LocalBackupService(
        _repository(secondDb),
        documentsDirectory: () async => documentsDirectory,
      );
      addTearDown(restore.dispose);

      final result = await restore.restoreFromLatestDetailed();
      expect(result.succeeded, isTrue);
      expect(result.restoredCount, 1);
      final persisted = await _repository(secondDb).getNotebook(source.uid);
      expect(persisted, isNotNull);
      _verifyContent(persisted!, uid: source.uid);
    },
  );
}
