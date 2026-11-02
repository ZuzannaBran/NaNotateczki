import 'package:sqlite3/common.dart';

/// Installs an ephemeral VFS before opening the guest's WASM database.
void registerSharedGuestVfs(CommonSqlite3 sqlite3) {
  sqlite3.registerVirtualFileSystem(
    InMemoryFileSystem(),
    makeDefault: true,
  );
}
