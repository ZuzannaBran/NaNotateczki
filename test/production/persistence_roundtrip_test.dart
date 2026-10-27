import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/ink_color_presets.dart';
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

  @override
  Future<String?> getApplicationSupportPath() async => documentsPath;
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

  test('touch navigation sensitivity survives a fresh startup', () async {
    final original = AppPreferencesController();
    expect(original.touchNavigationSensitivity, 1.0);
    await original.setTouchNavigationSensitivity(1.8);
    original.dispose();

    final reloaded = AppPreferencesController();
    await reloaded.load();
    expect(reloaded.touchNavigationSensitivity, 1.8);
    await reloaded.setTouchNavigationSensitivity(0.5);
    reloaded.dispose();

    final latest = AppPreferencesController();
    await latest.load();
    expect(latest.touchNavigationSensitivity, 0.5);
    latest.dispose();
  });

  test('interface scale persists after a fresh startup', () async {
    final original = AppPreferencesController();
    expect(original.uiScale, 1.0);
    original.previewUiScale(1.3);
    expect(original.uiScale, 1.3);
    await original.setUiScale(1.3);
    original.dispose();

    final reloaded = AppPreferencesController();
    await reloaded.load();
    expect(reloaded.uiScale, 1.3);
    reloaded.previewUiScale(5.0);
    expect(reloaded.uiScale, 1.5);
    reloaded.previewUiScale(double.nan);
    expect(reloaded.uiScale, 1.5);
    await reloaded.setUiScale(0.75);
    reloaded.dispose();

    final latest = AppPreferencesController();
    await latest.load();
    expect(latest.uiScale, 0.75);
    latest.dispose();
  });

  test('quick colors start blue and a selected palette persists', () async {
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = _repository(db);
    final controller = EditorController(
      repository: repository,
      notebook: _fixture(uid: 'palette-default'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.quickColors, InkColorPreset.blue.colors);
    expect(controller.penColor, InkColorPreset.blue.colors[0]);
    expect(controller.highlighterColor, InkColorPreset.blue.colors[0]);

    for (final preset in InkColorPreset.values) {
      controller.applyInkColorPreset(preset);
      expect(controller.quickColors, preset.colors);
      expect(controller.penColor, preset.colors[0]);
      expect(controller.highlighterColor, preset.colors[0]);
    }
    await controller.flushPendingSaves();
    controller.dispose();

    final persisted =
        jsonDecode((await readStoredText('editor_prefs.json'))!)
            as Map<String, dynamic>;
    expect(persisted['quickColors'], ['#1f3027', '#73af8e', '#99c2a8']);
    expect(persisted['penColor'], '#1f3027');
    expect(persisted['highlighterColor'], '#1f3027');
    expect(
      persisted['backgroundDefaults'],
      allOf(
        containsPair('notebook', isA<Map>()),
        containsPair('board', isA<Map>()),
      ),
    );
  });

  test(
    'legacy default quick swatches migrate without wiping custom colors',
    () async {
      await writeStoredText(
        'editor_prefs.json',
        jsonEncode({
          'penColor': '#1e2a40',
          'highlighterColor': '#536783',
          'quickColors': ['#1e1e1e', '#d32f2f', '#2e7d32'],
        }),
      );
      final db = NotesDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final controller = EditorController(
        repository: _repository(db),
        notebook: _fixture(uid: 'palette-migration'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controller.quickColors, InkColorPreset.blue.colors);
      expect(controller.penColor, InkColorPreset.blue.colors[0]);
      expect(controller.highlighterColor, InkColorPreset.blue.colors[0]);
      await controller.flushPendingSaves();
      controller.dispose();

      final persisted =
          jsonDecode((await readStoredText('editor_prefs.json'))!)
              as Map<String, dynamic>;
      expect(persisted['quickColors'], ['#1a2130', '#6a8ab9', '#8aaad1']);
    },
  );

  test(
    'latest factory swatches migrate without changing a selected shade',
    () async {
      await writeStoredText(
        'editor_prefs.json',
        jsonEncode({
          'penColor': '#6c3c4d',
          'highlighterColor': '#8e5066',
          'quickColors': ['#3a212b', '#6c3c4d', '#8e5066'],
        }),
      );
      final db = NotesDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final controller = EditorController(
        repository: _repository(db),
        notebook: _fixture(uid: 'palette-latest-migration'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.quickColors, InkColorPreset.pink.colors);
      expect(controller.inkColor, InkColorPreset.pink.colors[1]);
      controller.setTool(DrawingTool.highlighter);
      expect(controller.inkColor, InkColorPreset.pink.colors[1]);
      controller.dispose();
    },
  );

  test('previous factory swatches migrate by position in every palette',
      () async {
    const previousVersions = <Map<InkColorPreset, List<String>>>[
      {
        InkColorPreset.blue: ['#1a2130', '#acbed8', '#dee7f2'],
        InkColorPreset.pink: ['#3a212b', '#dab5c2', '#f2e1e8'],
        InkColorPreset.green: ['#1f3027', '#b0d2bf', '#e4efe8'],
      },
      {
        InkColorPreset.blue: ['#1a2130', '#7798c0', '#acbed8'],
        InkColorPreset.pink: ['#3a212b', '#a9788a', '#dab5c2'],
        InkColorPreset.green: ['#1f3027', '#76a58d', '#b0d2bf'],
      },
    ];
    for (final previous in previousVersions) {
      for (final entry in previous.entries) {
        await writeStoredText(
          'editor_prefs.json',
          jsonEncode({
            'penColor': entry.value[1],
            'highlighterColor': entry.value[1],
            'quickColors': entry.value,
          }),
        );
        final db = NotesDatabase(NativeDatabase.memory());
        final controller = EditorController(
          repository: _repository(db),
          notebook: _fixture(uid: 'previous-${entry.key.name}'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(controller.quickColors, entry.key.colors);
        expect(controller.inkColor, entry.key.colors[1]);
        await controller.flushPendingSaves();
        controller.dispose();
        await db.close();
      }
    }
  });

  test('custom quick swatches survive startup unchanged', () async {
    await writeStoredText(
      'editor_prefs.json',
      jsonEncode({
        'penColor': '#123456',
        'highlighterColor': '#654321',
        'quickColors': ['#123456', '#654321', '#abcdef'],
      }),
    );
    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final controller = EditorController(
      repository: _repository(db),
      notebook: _fixture(uid: 'custom-palette'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.quickColors, const [
      Color(0xFF123456),
      Color(0xFF654321),
      Color(0xFFABCDEF),
    ]);
    expect(controller.penColor, const Color(0xFF123456));
    expect(controller.highlighterColor, const Color(0xFF123456));
    controller.dispose();
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
