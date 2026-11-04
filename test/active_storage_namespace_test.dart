import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/active_storage_namespace.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';

void main() {
  test('local and account profiles select distinct stores', () {
    final local = ActiveStorageNamespace.fromProfile(null);
    final account = ActiveStorageNamespace.fromProfile(
      '{"version":1,"preferredMode":"account",'
      '"boundUserId":"00112233-4455-6677-8899-aabbccddeeff"}',
    );
    expect(local, StorageNamespace.local());
    expect(account, StorageNamespace.account(
      '00112233-4455-6677-8899-aabbccddeeff',
    ));
    expect(account.webDatabaseName, isNot(local.webDatabaseName));
    expect(account.nativeDatabaseName, isNot(local.nativeDatabaseName));
  });

  test('two account identities cannot share local storage keys', () {
    final a = StorageNamespace.account(
      '00112233-4455-6677-8899-aabbccddeeff',
    );
    final b = StorageNamespace.account(
      '00112233-4455-6677-8899-aabbccddeaaa',
    );
    expect(a.webDatabaseName, isNot(b.webDatabaseName));
    expect(a.fileKey('study_planner.json'),
        isNot(b.fileKey('study_planner.json')));
  });

  test('invalid profile account identity is rejected', () {
    expect(
      () => ActiveStorageNamespace.fromProfile(
        '{"version":1,"preferredMode":"account",'
        '"boundUserId":"../../root"}',
      ),
      throwsFormatException,
    );
  });
}
