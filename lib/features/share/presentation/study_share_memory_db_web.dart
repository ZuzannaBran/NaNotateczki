import 'package:drift/wasm.dart';
import 'package:sqlite3/wasm.dart';

import '../../../data/drift/notes_database.dart';

/// An isolated, ephemeral database with no access to the owner's library.
Future<NotesDatabase> openSharedGuestDatabase() async {
  final sqlite = await WasmSqlite3.loadFromUrl(
    Uri.parse('sqlite3.wasm'),
  );
  return NotesDatabase(WasmDatabase.inMemory(sqlite));
}
