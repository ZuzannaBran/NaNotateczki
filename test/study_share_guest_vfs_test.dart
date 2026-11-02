import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/study_share_guest_vfs.dart';
import 'package:sqlite3/common.dart';

class _RecordingSqlite3 implements CommonSqlite3 {
  VirtualFileSystem? fileSystem;
  bool? isDefault;

  @override
  void registerVirtualFileSystem(
    VirtualFileSystem vfs, {
    bool makeDefault = false,
  }) {
    fileSystem = vfs;
    isDefault = makeDefault;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  test('guest SQLite registers an in-memory VFS as the default', () {
    final sqlite = _RecordingSqlite3();
    registerSharedGuestVfs(sqlite);
    expect(sqlite.fileSystem, isA<InMemoryFileSystem>());
    expect(sqlite.isDefault, isTrue);
  });
}
