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

  test('changed notebook retains previous file for history', () async {
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
    expect(
      await historicalManifests.single.readAsString(),
      contains(firstFile),
    );
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
    final second = _distinctNotebook();

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

  test('manifest checksum detects a silently removed notebook entry', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final first = _notebook();
    final second = _distinctNotebook();

    await service.snapshot([first, second]);
    final newerSecond = second.copyWith(
      title: 'Newer',
      updatedAt: second.updatedAt.add(const Duration(seconds: 1)),
    );
    await service.snapshot([first, newerSecond]);

    final manifest = File('${directory.path}/local_backup/manifest.json');
    final decoded =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final entries = decoded['notebooks'] as List<dynamic>;
    decoded['notebooks'] = [entries.last];
    await manifest.writeAsString(jsonEncode(decoded), flush: true);

    final restored = await service.readLatest();

    expect(restored.map((item) => item.uid).toSet(), {first.uid, second.uid});
    expect(
      restored.singleWhere((item) => item.uid == second.uid).title,
      second.title,
    );
  });

  test(
    'snapshot never overwrites an unknown future manifest version',
    () async {
      final directory = await Directory.systemTemp.createTemp('backup-test-');
      addTearDown(() => directory.delete(recursive: true));
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final service = LocalBackupService(
        NotebookRepository(database),
        documentsDirectory: () async => directory,
      );
      final backupDir = Directory('${directory.path}/local_backup');
      await backupDir.create(recursive: true);
      final manifest = File('${backupDir.path}/manifest.json');
      const futureManifest = '{"version":99,"notebooks":[]}';
      await manifest.writeAsString(futureManifest, flush: true);

      await expectLater(
        service.snapshot([_notebook()]),
        throwsA(isA<BackupDataException>()),
      );

      expect(await manifest.readAsString(), futureManifest);
    },
  );

  test('version 2 FNV checksum remains recoverable', () async {
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
    final content = jsonEncode(NotebookRepository.encodeNotebook(notebook));
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(content)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final checksum = hash.toRadixString(16).padLeft(8, '0');
    final backupDir = Directory('${directory.path}/local_backup/notebooks');
    await backupDir.create(recursive: true);
    const fileName = 'notebook_legacy.json';
    await File(
      '${backupDir.path}/$fileName',
    ).writeAsString(content, flush: true);
    await File('${directory.path}/local_backup/manifest.json').writeAsString(
      jsonEncode({
        'version': 2,
        'notebooks': [
          {
            'uid': notebook.uid,
            'updatedAt': notebook.updatedAt.toIso8601String(),
            'file': fileName,
            'checksum': checksum,
            'bytes': utf8.encode(content).length,
          },
        ],
      }),
      flush: true,
    );

    final restored = await service.readLatest();

    expect(restored, hasLength(1));
    expect(restored.single.uid, notebook.uid);
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

  test('legacy full backup never decodes partially', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = LocalBackupService(
      repository,
      documentsDirectory: () async => directory,
    );
    final legacyDir = Directory('${directory.path}/local_backup');
    await legacyDir.create(recursive: true);
    await File('${legacyDir.path}/notebooks_latest.json').writeAsString(
      jsonEncode([
        NotebookRepository.encodeNotebook(_notebook()),
        'not-a-notebook',
      ]),
      flush: true,
    );

    final restored = await service.readLatest();

    expect(restored, isEmpty);
  });

  test('version 1 backup rejects malformed nested content', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = LocalBackupService(
      repository,
      documentsDirectory: () async => directory,
    );
    final encoded = NotebookRepository.encodeNotebook(_notebook());
    final pages = encoded['pages'] as List<dynamic>;
    final page = pages.single as Map<String, dynamic>;
    page['imageBlocks'] = ['broken'];
    final backupDir = Directory('${directory.path}/local_backup/notebooks');
    await backupDir.create(recursive: true);
    const fileName = 'malformed_v1.json';
    await File(
      '${backupDir.path}/$fileName',
    ).writeAsString(jsonEncode(encoded), flush: true);
    await File('${directory.path}/local_backup/manifest.json').writeAsString(
      jsonEncode({
        'version': 1,
        'notebooks': [
          {
            'uid': _notebook().uid,
            'updatedAt': _notebook().updatedAt.toIso8601String(),
            'file': fileName,
          },
        ],
      }),
      flush: true,
    );

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
    final repository = NotebookRepository(database, onChanged: () => changed++);
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
    expect(saved.map((item) => item.uid).toSet(), {first.uid, second.uid});
  });

  test('snapshot rejects duplicate nested ids before writing', () async {
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

    await expectLater(
      service.snapshot([first, second]),
      throwsA(isA<BackupDataException>()),
    );

    final manifest = File('${directory.path}/local_backup/manifest.json');
    expect(await manifest.exists(), isFalse);
  });

  test('required uid lookup falls back to history', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final protected = _notebook();
    final healthy = _distinctNotebook();

    await service.snapshot([protected, healthy]);
    final newerHealthy = healthy.copyWith(
      title: 'Healthy newer',
      updatedAt: healthy.updatedAt.add(const Duration(seconds: 2)),
    );
    await service.snapshot([newerHealthy]);

    final latest = await service.readLatest();
    final recovery = await service.readLatest(requiredUids: {protected.uid});

    expect(latest.map((item) => item.uid), [healthy.uid]);
    expect(recovery.map((item) => item.uid).toSet(), {
      protected.uid,
      healthy.uid,
    });
  });

  test('safe historical copy can be carried into a new snapshot', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final protected = _notebook();
    final healthy = _distinctNotebook();

    await service.snapshot([protected, healthy]);
    final newerHealthy = healthy.copyWith(
      title: 'Healthy newer',
      updatedAt: healthy.updatedAt.add(const Duration(seconds: 2)),
    );
    await service.snapshot([newerHealthy]);
    final protectedRecovery = await service.readLatest(
      requiredUids: {protected.uid},
    );
    final safeProtected = protectedRecovery.singleWhere(
      (item) => item.uid == protected.uid,
    );

    await service.snapshot([newerHealthy, safeProtected]);
    final latest = await service.readLatest();

    expect(latest.map((item) => item.uid).toSet(), {
      protected.uid,
      healthy.uid,
    });
    expect(
      latest.singleWhere((item) => item.uid == protected.uid).updatedAt,
      protected.updatedAt,
    );
  });

  test('snapshot rejects an older version of an existing notebook', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final first = _notebook();
    final newer = first.copyWith(
      title: 'Newer',
      updatedAt: first.updatedAt.add(const Duration(seconds: 2)),
    );
    final older = first.copyWith(
      title: 'Older',
      updatedAt: first.updatedAt.add(const Duration(seconds: 1)),
    );

    await service.snapshot([newer]);
    await service.snapshot([older]);
    final restored = await service.readLatest();

    expect(restored.single.title, 'Newer');
    expect(restored.single.updatedAt, newer.updatedAt);
  });

  test('snapshot cleans orphaned atomic temp files', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final notebooksDir = Directory('${directory.path}/local_backup/notebooks');
    await notebooksDir.create(recursive: true);
    final orphan = File('${notebooksDir.path}/orphan.json.tmp');
    await orphan.writeAsString('partial', flush: true);

    await service.snapshot([_notebook()]);

    expect(await orphan.exists(), isFalse);
  });

  test('snapshot restores empty library folders from its manifest', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final service = LocalBackupService(
      repository,
      documentsDirectory: () async => directory,
    );
    final folders = File('${directory.path}/library_folders.json');
    await folders.writeAsString(
      jsonEncode(['Empty Folder', 'Notes']),
      flush: true,
    );

    await service.snapshot([_notebook()]);
    await folders.writeAsString(jsonEncode(['Notes']), flush: true);
    final report = await service.restoreFromLatestDetailed();

    expect(report.succeeded, isTrue);
    expect(
      jsonDecode(await folders.readAsString()),
      containsAll(['Empty Folder', 'Notes']),
    );
  });

  test('empty valid snapshot is a successful restore', () async {
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
    final report = await service.restoreFromLatestDetailed();

    expect(report.snapshotFound, isTrue);
    expect(report.succeeded, isTrue);
    expect(report.restoredCount, 0);
    expect(await repository.fetchNotebooks(), isEmpty);
  });

  test(
    'invalid snapshot is not reported as a successful empty restore',
    () async {
      final directory = await Directory.systemTemp.createTemp('backup-test-');
      addTearDown(() => directory.delete(recursive: true));
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final service = LocalBackupService(
        NotebookRepository(database),
        documentsDirectory: () async => directory,
      );
      final backupDir = Directory('${directory.path}/local_backup');
      await backupDir.create(recursive: true);
      await File(
        '${backupDir.path}/manifest.json',
      ).writeAsString('{"version":3,"notebooks":"broken"}', flush: true);

      final report = await service.restoreFromLatestDetailed();

      expect(report.succeeded, isFalse);
      expect(report.snapshotFound, isFalse);
      expect(report.restoredCount, 0);
    },
  );

  test(
    'document restore stays successful if folder metadata write fails',
    () async {
      final directory = await Directory.systemTemp.createTemp('backup-test-');
      addTearDown(() => directory.delete(recursive: true));
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final service = LocalBackupService(
        repository,
        documentsDirectory: () async => directory,
      );

      await service.snapshot([_notebook()]);
      final foldersPath = '${directory.path}/library_folders.json';
      final foldersDir = Directory(foldersPath);
      await foldersDir.create(recursive: true);

      final report = await service.restoreFromLatestDetailed();

      expect(report.succeeded, isTrue);
      expect(report.restoredCount, 1);
      expect(await repository.fetchNotebooks(), hasLength(1));
    },
  );

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
