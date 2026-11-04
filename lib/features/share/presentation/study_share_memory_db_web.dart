import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/wasm.dart';
import 'package:sqlite3/wasm.dart';

import '../../../data/drift/notes_database.dart';
import '../../../data/sync/study_share_guest_vfs.dart';
import '../../../data/sync/study_share_web_assets.dart';

/// An isolated, ephemeral database with no access to the owner's library.
Future<NotesDatabase> openSharedGuestDatabase() async {
  final sqlite = await WasmSqlite3.loadFromUrl(sharedGuestWasmUri(Uri.base));
  registerSharedGuestVfs(sqlite);
  return NotesDatabase(WasmDatabase.inMemory(sqlite));
}

/// A durable per-invitation and per-guest journal, never the account DB.
///
/// Unlike the v1 preview database, this stores unacknowledged v2 intents
/// across browser reloads. It must not be cleared before explicit ACK or
/// recoverable session closure. Stage 7 may move this into a namespace manager.
Future<NotesDatabase> openSharedGuestOperationDatabase(
  String shareId, {
  required String guestActorId,
}) async {
  if (!RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(shareId)) {
    throw const FormatException('Invalid shared session ID.');
  }
  if (guestActorId.isEmpty ||
      guestActorId.length > 128 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(guestActorId)) {
    throw const FormatException('Invalid guest actor namespace.');
  }
  final key = sha256
      .convert(utf8.encode(jsonEncode([shareId.toLowerCase(), guestActorId])))
      .toString();
  final sqlite = await WasmSqlite3.loadFromUrl(sharedGuestWasmUri(Uri.base));
  final fileSystem = await IndexedDbFileSystem.open(
    dbName: 'nanotateczki_share_ops_v2_$key',
  );
  sqlite.registerVirtualFileSystem(fileSystem, makeDefault: true);
  return NotesDatabase(
    WasmDatabase(sqlite3: sqlite, path: '/database', fileSystem: fileSystem),
  );
}
