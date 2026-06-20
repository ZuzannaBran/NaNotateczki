import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

class NotesDatabaseConnection {
  NotesDatabaseConnection({required this.executor, required this.freshFile});

  final QueryExecutor executor;
  final bool freshFile;
}

Future<NotesDatabaseConnection> openNotesDatabaseConnection(String name) async {
  final result = await WasmDatabase.open(
    databaseName: name,
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.dart.js'),
  );
  return NotesDatabaseConnection(
    executor: result.resolvedExecutor,
    freshFile: false,
  );
}
