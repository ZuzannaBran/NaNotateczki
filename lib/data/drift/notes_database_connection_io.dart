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
  return NotesDatabaseConnection(
    executor: NativeDatabase.createInBackground(file),
    freshFile: !file.existsSync(),
  );
}
