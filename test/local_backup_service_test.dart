import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unchanged notebook reuses its incremental backup', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final notebook = _notebook();

    final first = await service.snapshot([notebook]);
    final second = await service.snapshot([notebook]);

    expect(first.changedCount, 1);
    expect(second.changedCount, 0);
    expect(second.unchangedCount, 1);
    expect(second.notebookReports.single.flattenMs, 0);
    expect(second.notebookReports.single.encodeMs, 0);
    expect(second.notebookReports.single.jsonMs, 0);
  });

  test(
    'changed notebook retains previous file for history',
    () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final notebook = _notebook();

    await service.snapshot([notebook]);
    final manifest = File('${directory.path}/local_backup/manifest.json');
    final firstManifest =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final firstEntry =
        (firstManifest['notebooks'] as List<dynamic>).single
            as Map<String, dynamic>;
    final firstFile = firstEntry['file'] as String;

    final updated = notebook.copyWith(
      updatedAt: notebook.updatedAt.add(const Duration(seconds: 1)),
    );
    await service.snapshot([updated]);

    final secondManifest =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final secondEntry =
        (secondManifest['notebooks'] as List<dynamic>).single
            as Map<String, dynamic>;
    final secondFile = secondEntry['file'] as String;

    expect(secondFile, isNot(firstFile));
    expect(
      File('${directory.path}/local_backup/notebooks/$secondFile').existsSync(),
      isTrue,
    );
    expect(
      File('${directory.path}/local_backup/notebooks/$firstFile').existsSync(),
      isTrue,
    );
    final history = Directory('${directory.path}/local_backup/history');
    final historicalManifests = history
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();
    expect(historicalManifests, hasLength(1));
    expect(await historicalManifests.single.readAsString(), contains(firstFile));
    expect(File('${manifest.path}.tmp').existsSync(), isFalse);
    expect(File('${manifest.path}.previous').existsSync(), isFalse);
  });

  test('checksum detects and repairs a corrupted notebook backup', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final notebook = _notebook();

    await service.snapshot([notebook]);
    final manifest = File('${directory.path}/local_backup/manifest.json');
    final decoded =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final entry =
        (decoded['notebooks'] as List<dynamic>).single as Map<String, dynamic>;
    final backupFile = File(
      '${directory.path}/local_backup/notebooks/${entry['file']}',
    );
    await backupFile.writeAsString('{"broken":');

    final repaired = await service.snapshot([notebook]);

    expect(repaired.changedCount, 1);
    expect(jsonDecode(await backupFile.readAsString()), isA<Map>());
    final repairedManifest =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final repairedEntry =
        (repairedManifest['notebooks'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(repairedEntry['checksum'], isA<String>());
    expect(repairedEntry['bytes'], greaterThan(0));
  });

  test('readLatest never returns a partial corrupted snapshot', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final first = _notebook();
    final second = first.copyWith(
      uid: 'notebook-2',
      title: 'Second',
      updatedAt: first.updatedAt.add(const Duration(seconds: 1)),
    );

    await service.snapshot([first, second]);
    final manifest = File('${directory.path}/local_backup/manifest.json');
    final decoded =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final entries = decoded['notebooks'] as List<dynamic>;
    final brokenEntry = entries.last as Map<String, dynamic>;
    final brokenFile = File(
      '${directory.path}/local_backup/notebooks/${brokenEntry['file']}',
    );
    await brokenFile.writeAsString('{"broken":');

    final restored = await service.readLatest();

    expect(restored, isEmpty);
  });

  test('version 1 incremental manifest remains recoverable', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = LocalBackupService(
      repository,
      documentsDirectory: () async => directory,
    );
    final notebook = _notebook();
    final backupDir = Directory('${directory.path}/local_backup/notebooks');
    await backupDir.create(recursive: true);
    const fileName = 'notebook.json';
    await File('${backupDir.path}/$fileName').writeAsString(
      jsonEncode(NotebookRepository.encodeNotebook(notebook)),
      flush: true,
    );
    await File('${directory.path}/local_backup/manifest.json').writeAsString(
      jsonEncode({
        'version': 1,
        'notebooks': [
          {
            'uid': notebook.uid,
            'updatedAt': notebook.updatedAt.toIso8601String(),
            'file': fileName,
          },
        ],
      }),
      flush: true,
    );

    final restored = await service.readLatest();

    expect(restored, hasLength(1));
    expect(restored.single.uid, notebook.uid);
    expect(restored.single.updatedAt, notebook.updatedAt);
  });

  test('duplicate notebook uid invalidates a manifest snapshot', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = LocalBackupService(
      repository,
      documentsDirectory: () async => directory,
    );
    final notebook = _notebook();
    await service.snapshot([notebook]);
    final manifest = File('${directory.path}/local_backup/manifest.json');
    final decoded =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final entries = decoded['notebooks'] as List<dynamic>;
    decoded['notebooks'] = [...entries, entries.single];
    await manifest.writeAsString(jsonEncode(decoded), flush: true);

    final restored = await service.readLatest();

    expect(restored, isEmpty);
  });

  test('empty incremental snapshot does not resurrect legacy data', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = LocalBackupService(
      repository,
      documentsDirectory: () async => directory,
    );

    await service.snapshot([]);
    final legacy = File('${directory.path}/local_backup/notebooks_latest.json');
    await legacy.writeAsString(
      jsonEncode(repository.encodeNotebooks([_notebook()])),
    );

    final restored = await service.readLatest();

    expect(restored, isEmpty);
  });

  test('readLatest falls back to the newest valid history snapshot', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final first = _notebook();

    await service.snapshot([first]);
    final second = first.copyWith(
      title: 'Newer title',
      updatedAt: first.updatedAt.add(const Duration(seconds: 1)),
    );
    await service.snapshot([second]);

    final manifest = File('${directory.path}/local_backup/manifest.json');
    final decoded =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final entry =
        (decoded['notebooks'] as List<dynamic>).single as Map<String, dynamic>;
    final currentFile = File(
      '${directory.path}/local_backup/notebooks/${entry['file']}',
    );
    await currentFile.writeAsString('{"broken":');

    final restored = await service.readLatest();

    expect(restored, hasLength(1));
    expect(restored.single.title, first.title);
    expect(restored.single.updatedAt, first.updatedAt);
  });

  test('history keeps only five previous manifests', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    var notebook = _notebook();

    for (var index = 0; index < 8; index++) {
      notebook = notebook.copyWith(
        title: 'Version $index',
        updatedAt: notebook.updatedAt.add(const Duration(seconds: 1)),
      );
      await service.snapshot([notebook]);
    }

    final history = Directory('${directory.path}/local_backup/history');
    final manifests = history
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();

    expect(manifests.length, lessThanOrEqualTo(5));
  });

  test('missing image never replaces the last good backup', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final imageFile = File('${directory.path}/image.png');
    await imageFile.writeAsBytes([1, 2, 3, 4], flush: true);
    final base = _notebook();
    final withImage = base.copyWith(
      pages: [
        base.pages.single.copyWith(
          imageBlocks: [
            ImageBlock(
              id: 'image',
              path: imageFile.path,
              ocrText: '',
              position: Offset.zero,
              width: 100,
              height: 100,
              imageExt: 'png',
              imageMime: 'image/png',
            ),
          ],
        ),
      ],
    );

    await service.snapshot([withImage]);
    await imageFile.delete();
    final changed = withImage.copyWith(
      title: 'Changed after image disappeared',
      updatedAt: withImage.updatedAt.add(const Duration(seconds: 1)),
    );

    await expectLater(
      service.snapshot([changed]),
      throwsA(isA<BackupDataException>()),
    );

    final restored = await service.readLatest();
    expect(restored, hasLength(1));
    expect(restored.single.updatedAt, withImage.updatedAt);
    expect(restored.single.pages.single.imageBlocks, hasLength(1));
    expect(restored.single.pages.single.imageBlocks.single.bytes, isNotEmpty);
  });

  test('restore commits a complete batch and notifies once', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    var changed = 0;
    final repository = NotebookRepository(
      database,
      onChanged: () => changed++,
    );
    final service = LocalBackupService(
      repository,
      documentsDirectory: () async => directory,
    );
    final first = _notebook();
    final second = _distinctNotebook();

    await service.snapshot([first, second]);
    final restored = await service.restoreFromLatest();

    expect(restored, 2);
    expect(changed, 1);
    final saved = await repository.fetchNotebooks();
    expect(saved.map((item) => item.uid).toSet(), {
      first.uid,
      second.uid,
    });
  });

  test('restore rolls back the batch when ids collide', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = LocalBackupService(
      repository,
      documentsDirectory: () async => directory,
    );
    final first = _notebook();
    final second = first.copyWith(
      uid: 'notebook-2',
      updatedAt: first.updatedAt.add(const Duration(seconds: 1)),
    );

    await service.snapshot([first, second]);
    final restored = await service.restoreFromLatest();

    expect(restored, 0);
    expect(await repository.fetchNotebooks(), isEmpty);
  });

  test('snapshot stops when ink becomes active', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );

    await expectLater(
      service.snapshot([_notebook()], shouldInterrupt: () => true),
      throwsA(isA<BackupSnapshotInterrupted>()),
    );
  });

  test('snapshot interrupts an active backup worker', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final snapshotStates = <bool>[];
    service.snapshotInProgress.addListener(
      () => snapshotStates.add(service.snapshotInProgress.value),
    );
    var interruptChecks = 0;

    await expectLater(
      service.snapshot([
        _largeNotebook(),
      ], shouldInterrupt: () => ++interruptChecks >= 3),
      throwsA(isA<BackupSnapshotInterrupted>()),
    );

    expect(interruptChecks, greaterThanOrEqualTo(3));
    expect(service.snapshotInProgress.value, isFalse);
    expect(snapshotStates, containsAllInOrder([true, false]));
  });
}

Notebook _notebook() {
  final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);
  return Notebook(
    uid: 'notebook',
    title: 'Notebook',
    kind: NotebookKind.notebook,
    folder: 'Notes',
    createdAt: timestamp,
    updatedAt: timestamp,
    pages: [
      NotePage(
        id: 'page',
        title: 'Page',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: [
          InkStroke(
            id: 'stroke',
            points: const [
              InkPoint(dx: 0, dy: 0, pressure: 0.5),
              InkPoint(dx: 10, dy: 10, pressure: 0.5),
            ],
            color: Color(0xFF000000),
            width: 2,
            tool: DrawingTool.pen,
          ),
        ],
        isBookmarked: false,
        indexTabs: const [],
      ),
    ],
  );
}

Notebook _distinctNotebook() {
  final first = _notebook();
  final page = first.pages.single;
  return first.copyWith(
    uid: 'notebook-2',
    title: 'Notebook 2',
    updatedAt: first.updatedAt.add(const Duration(seconds: 1)),
    pages: [
      page.copyWith(
        id: 'page-2',
        inkStrokes: [
          for (final stroke in page.inkStrokes)
            stroke.copyWith(id: '${stroke.id}-2'),
        ],
      ),
    ],
  );
}

Notebook _largeNotebook() {
  final notebook = _notebook();
  final strokes =
      List<InkStroke>.generate(
        1200,
        (strokeIndex) => InkStroke(
          id: 'stroke-$strokeIndex',
          points: List<InkPoint>.generate(
            40,
            (pointIndex) => InkPoint(
              dx: pointIndex.toDouble(),
              dy: strokeIndex.toDouble(),
              pressure: 0.5,
            ),
          ),
          color: const Color(0xFF000000),
          width: 2,
          tool: DrawingTool.pen,
        ),
      )..add(
        InkStroke(
          id: 'eraser',
          points: List<InkPoint>.generate(
            200,
            (index) => InkPoint(dx: index / 5, dy: index * 6, pressure: 0.5),
          ),
          color: const Color(0xFF000000),
          width: 8,
          tool: DrawingTool.eraserBrush,
        ),
      );
  return notebook.copyWith(
    pages: [notebook.pages.single.copyWith(inkStrokes: strokes)],
  );
}
