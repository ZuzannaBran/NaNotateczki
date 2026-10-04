import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

class NotesDatabaseConnection {
  NotesDatabaseConnection({required this.executor, required this.freshFile});

  final QueryExecutor executor;
  final bool freshFile;
}

Future<NotesDatabaseConnection> openNotesDatabaseConnection(String name) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$name');
  final freshFile = !file.existsSync();
  return NotesDatabaseConnection(
    executor: NativeDatabase.createInBackground(file),
    freshFile: freshFile,
  );
}

Future<String?> quarantineNotesDatabase(String name) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$name');
  if (!await file.exists()) {
    return null;
  }

  final timestamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '-');
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
  return quarantinePath;
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
