import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'app_data_migration_report.dart';

const _dataDirectoryName = 'data';
const _migrationMarkerName = 'storage_layout.json';
const _layoutVersion = 1;

const _legacyFiles = <String>[
  'notes.sqlite',
  'notes.sqlite-wal',
  'notes.sqlite-shm',
  'notes.sqlite-journal',
  'notes.sqlite.recovery_pending',
  'notes.sqlite.recovery_pending.previous',
  'notes.sqlite.recovery_pending.tmp',
  'app_prefs.json',
  'app_prefs.json.previous',
  'app_prefs.json.tmp',
  'editor_prefs.json',
  'editor_prefs.json.previous',
  'editor_prefs.json.tmp',
  'shared_recent_colors.json',
  'shared_recent_colors.json.previous',
  'shared_recent_colors.json.tmp',
  'library_folders.json',
  'library_folders.json.previous',
  'library_folders.json.tmp',
  'study_planner.json',
  'study_planner.json.previous',
  'study_planner.json.tmp',
  'app_error_log.json',
  'data_integrity_log.json',
  'optimization_log.json',
  'cloud_sync.json',
];

const _legacyDirectories = <String>[
  'images',
  'local_backup',
  'deleted_notebooks',
  'data_integrity_incidents',
];

Future<AppDataMigrationReport> migrateNativeAppData({
  required String supportPath,
  required String legacyDocumentsPath,
}) async {
  final support = Directory(supportPath);
  final legacy = Directory(legacyDocumentsPath);
  final data = Directory('${support.path}/$_dataDirectoryName');
  await data.create(recursive: true);
  await _restrictPermissions(data);

  if (_samePath(data.path, legacy.path)) {
    return AppDataMigrationReport(dataPath: data.path);
  }

  final migrated = <String>[];
  final conflicts = <String>[];
  if (!await legacy.exists()) {
    await _writeMigrationMarker(
      data,
      sourcePath: legacy.path,
      migrated: migrated,
      conflicts: conflicts,
    );
    return AppDataMigrationReport(dataPath: data.path);
  }
  for (final name in _legacyFiles) {
    final source = File('${legacy.path}/$name');
    if (!await source.exists()) {
      continue;
    }
    final target = File('${data.path}/$name');
    final result = await _migrateFile(source, target);
    if (result == _MigrationResult.migrated) {
      migrated.add(name);
    } else if (result == _MigrationResult.conflict) {
      conflicts.add(name);
    }
  }
  await for (final entity in legacy.list(followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final name = _baseName(entity.path);
    if (name != 'schema_version.txt' && !name.startsWith('default.isar')) {
      continue;
    }
    final result = await _migrateFile(
      entity,
      File('${data.path}/legacy/$name'),
    );
    final relativePath = 'legacy/$name';
    if (result == _MigrationResult.migrated) {
      migrated.add(relativePath);
    } else if (result == _MigrationResult.conflict) {
      conflicts.add(relativePath);
    }
  }
  for (final name in _legacyDirectories) {
    final source = Directory('${legacy.path}/$name');
    if (!await source.exists()) {
      continue;
    }
    final target = Directory('${data.path}/$name');
    await _migrateDirectory(
      source,
      target,
      relativePrefix: name,
      migrated: migrated,
      conflicts: conflicts,
    );
    if (await source.exists() && await source.list().isEmpty) {
      await source.delete();
    }
  }

  await _writeMigrationMarker(
    data,
    sourcePath: legacy.path,
    migrated: migrated,
    conflicts: conflicts,
  );
  return AppDataMigrationReport(
    dataPath: data.path,
    migratedPaths: List.unmodifiable(migrated),
    conflictingPaths: List.unmodifiable(conflicts),
  );
}

Future<void> _migrateDirectory(
  Directory source,
  Directory target, {
  required String relativePrefix,
  required List<String> migrated,
  required List<String> conflicts,
}) async {
  await target.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name = _baseName(entity.path);
    final relativePath = '$relativePrefix/$name';
    if (entity is File) {
      final result = await _migrateFile(entity, File('${target.path}/$name'));
      if (result == _MigrationResult.migrated) {
        migrated.add(relativePath);
      } else if (result == _MigrationResult.conflict) {
        conflicts.add(relativePath);
      }
    } else if (entity is Directory) {
      await _migrateDirectory(
        entity,
        Directory('${target.path}/$name'),
        relativePrefix: relativePath,
        migrated: migrated,
        conflicts: conflicts,
      );
      if (await entity.exists() && await entity.list().isEmpty) {
        await entity.delete();
      }
    }
  }
}

Future<_MigrationResult> _migrateFile(File source, File target) async {
  await target.parent.create(recursive: true);
  if (await target.exists()) {
    if (await _filesMatch(source, target)) {
      await source.delete();
      return _MigrationResult.migrated;
    }
    return _MigrationResult.conflict;
  }

  final temporary = File('${target.path}.migrating');
  if (await temporary.exists()) {
    await temporary.delete();
  }
  await source.copy(temporary.path);
  final handle = await temporary.open(mode: FileMode.append);
  try {
    await handle.flush();
  } finally {
    await handle.close();
  }
  if (!await _filesMatch(source, temporary)) {
    await temporary.delete();
    throw FileSystemException(
      'App data migration checksum verification failed.',
      source.path,
    );
  }
  await temporary.rename(target.path);
  await source.delete();
  return _MigrationResult.migrated;
}

Future<bool> _filesMatch(File first, File second) async {
  if (await first.length() != await second.length()) {
    return false;
  }
  final digests = await Future.wait([
    sha256.bind(first.openRead()).first,
    sha256.bind(second.openRead()).first,
  ]);
  return digests[0].toString() == digests[1].toString();
}

Future<void> _writeMigrationMarker(
  Directory data, {
  required String sourcePath,
  required List<String> migrated,
  required List<String> conflicts,
}) async {
  final marker = File('${data.path}/$_migrationMarkerName');
  final temporary = File('${marker.path}.tmp');
  await temporary.writeAsString(
    jsonEncode({
      'version': _layoutVersion,
      'completedAt': DateTime.now().toUtc().toIso8601String(),
      'legacySource': sourcePath,
      'migratedPaths': migrated,
      'conflictingPaths': conflicts,
    }),
    flush: true,
  );
  if (await marker.exists()) {
    await marker.delete();
  }
  await temporary.rename(marker.path);
}

Future<void> _restrictPermissions(Directory directory) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return;
  }
  final result = await Process.run('chmod', ['700', directory.path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not restrict app data directory permissions.',
      directory.path,
    );
  }
}

String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

bool _samePath(String first, String second) {
  return Directory(first).absolute.path == Directory(second).absolute.path;
}

enum _MigrationResult { migrated, conflict }
