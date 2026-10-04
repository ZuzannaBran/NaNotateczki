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
  final moves = <(File source, File target)>[
    (
      File('${file.path}-wal'),
      File('$quarantinePath-wal'),
    ),
    (
      File('${file.path}-shm'),
      File('$quarantinePath-shm'),
    ),
    (file, File(quarantinePath)),
  ];
  final completed = <(File source, File target)>[];
  try {
    for (final move in moves) {
      if (!await move.$1.exists()) {
        continue;
      }
      await move.$1.rename(move.$2.path);
      completed.add(move);
    }
  } catch (_) {
    for (final move in completed.reversed) {
      if (await move.$2.exists() && !await move.$1.exists()) {
        await move.$2.rename(move.$1.path);
      }
    }
    rethrow;
  }
  return quarantinePath;
}
