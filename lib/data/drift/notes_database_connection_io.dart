import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/storage/app_data_directory.dart';

class NotesDatabaseConnection {
  NotesDatabaseConnection({
    required this.executor,
    required this.freshFile,
    this.recoveryPending = false,
    this.recoveryReason,
    this.legacyImageDirectory,
    this.imageDirectory,
  });

  final QueryExecutor executor;
  final bool freshFile;
  final bool recoveryPending;
  final String? recoveryReason;
  final String? legacyImageDirectory;
  final String? imageDirectory;
}

Future<NotesDatabaseConnection> openNotesDatabaseConnection(String name) async {
  final documents = await getApplicationDocumentsDirectory();
  final migration = await prepareAppDataDirectory(
    legacyDocumentsPath: documents.path,
  );
  final dir = Directory(migration.dataPath);
  final file = File('${dir.path}/$name');
  await file.parent.create(recursive: true);
  final marker = _recoveryMarker(file);
  await _recoverRecoveryMarker(marker);
  final freshFile = !file.existsSync();

  if (freshFile &&
      name == 'notes.sqlite' &&
      !await marker.exists() &&
      await _hasLocalRecoveryCandidate(dir)) {
    await _writeRecoveryMarker(
      marker,
      'A fresh SQLite database was opened while a local backup exists.',
    );
  }

  final recoveryPending = await marker.exists();
  String? recoveryReason;
  if (recoveryPending) {
    try {
      recoveryReason = await marker.readAsString();
    } catch (_) {
      recoveryReason = 'Local database recovery is pending.';
    }
  }

  return NotesDatabaseConnection(
    executor: NativeDatabase.createInBackground(
      file,
      setup: (database) {
        database.execute('PRAGMA journal_mode = WAL');
        database.execute('PRAGMA synchronous = FULL');
        database.execute('PRAGMA foreign_keys = ON');
      },
    ),
    freshFile: freshFile,
    recoveryPending: recoveryPending,
    recoveryReason: recoveryReason,
    legacyImageDirectory:
        name != 'notes.sqlite' ||
        migration.conflictingPaths.any((path) => path.startsWith('images/'))
        ? null
        : '${documents.path}/images',
    imageDirectory: '${file.parent.path}/images',
  );
}

Future<String?> quarantineNotesDatabase(String name) async {
  final dir = Directory(await getAppDataPath());
  final file = File('${dir.path}/$name');
  if (!await file.exists()) {
    return null;
  }

  final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    ':',
    '-',
  );
  final quarantinePath = '${file.path}.corrupt_$timestamp';
  final components = <(File source, File target)>[
    (File('${file.path}-wal'), File('$quarantinePath-wal')),
    (File('${file.path}-shm'), File('$quarantinePath-shm')),
    (File('${file.path}-journal'), File('$quarantinePath-journal')),
    (file, File(quarantinePath)),
  ];
  final existing = <(File source, File target)>[];
  for (final component in components) {
    if (await component.$1.exists()) {
      existing.add(component);
    }
  }

  for (final component in existing) {
    await _copyAndFlush(component.$1, component.$2);
  }

  final deleted = <(File source, File target)>[];
  try {
    for (final component in existing) {
      await component.$1.delete();
      deleted.add(component);
    }
  } catch (_) {
    for (final component in deleted.reversed) {
      if (!await component.$1.exists() && await component.$2.exists()) {
        await _copyAndFlush(component.$2, component.$1);
      }
    }
    rethrow;
  }
  await _writeRecoveryMarker(
    _recoveryMarker(file),
    'SQLite integrity failed. Quarantined database: $quarantinePath',
  );
  return quarantinePath;
}

Future<void> clearNotesDatabaseRecoveryMarker(String name) async {
  final dir = Directory(await getAppDataPath());
  final marker = _recoveryMarker(File('${dir.path}/$name'));
  await _recoverRecoveryMarker(marker);
  if (await marker.exists()) {
    await marker.delete();
  }
  final previous = File('${marker.path}.previous');
  final temporary = File('${marker.path}.tmp');
  if (await previous.exists()) {
    await previous.delete();
  }
  if (await temporary.exists()) {
    await temporary.delete();
  }
}

File _recoveryMarker(File databaseFile) {
  return File('${databaseFile.path}.recovery_pending');
}

Future<bool> _hasLocalRecoveryCandidate(Directory documentsDir) async {
  final backupDir = Directory('${documentsDir.path}/local_backup');
  if (!await backupDir.exists()) {
    return false;
  }
  if (await File('${backupDir.path}/manifest.json').exists() ||
      await File('${backupDir.path}/notebooks_latest.json').exists()) {
    return true;
  }
  final history = Directory('${backupDir.path}/history');
  if (!await history.exists()) {
    return false;
  }
  await for (final entity in history.list()) {
    if (entity is File && entity.path.endsWith('.json')) {
      return true;
    }
  }
  return false;
}

Future<void> _writeRecoveryMarker(File marker, String reason) async {
  await _recoverRecoveryMarker(marker);
  final temporary = File('${marker.path}.tmp');
  final previous = File('${marker.path}.previous');
  if (await temporary.exists()) {
    await temporary.delete();
  }
  if (await previous.exists()) {
    await previous.delete();
  }
  await temporary.writeAsString(reason, flush: true);
  if (await marker.exists()) {
    await marker.rename(previous.path);
  }
  try {
    await temporary.rename(marker.path);
    if (await previous.exists()) {
      await previous.delete();
    }
  } catch (_) {
    if (!await marker.exists() && await previous.exists()) {
      await previous.rename(marker.path);
    }
    rethrow;
  }
}

Future<void> _recoverRecoveryMarker(File marker) async {
  final temporary = File('${marker.path}.tmp');
  final previous = File('${marker.path}.previous');
  if (!await marker.exists() && await previous.exists()) {
    await previous.rename(marker.path);
  } else if (await previous.exists()) {
    await previous.delete();
  }
  if (await temporary.exists()) {
    await temporary.delete();
  }
}

Future<void> _copyAndFlush(File source, File target) async {
  await source.copy(target.path);
  final handle = await target.open(mode: FileMode.append);
  try {
    await handle.flush();
  } finally {
    await handle.close();
  }
}
