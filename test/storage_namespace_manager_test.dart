import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';

void main() {
  test('isolates Local, distinct accounts and independent share guests', () {
    final local = StorageNamespace.local();
    final a = StorageNamespace.account('user-a');
    final b = StorageNamespace.account('user-b');
    final guest = StorageNamespace.share('share-1', 'guest-1');
    final other = StorageNamespace.share('share-1', 'guest-2');

    expect(a, StorageNamespace.account('user-a'));
    expect({local, a, b, guest, other}, hasLength(5));
    expect(
      a.fileKey('study_planner.json'),
      isNot(b.fileKey('study_planner.json')),
    );
    expect(a.nativeDatabaseName, isNot(local.nativeDatabaseName));
    expect(a.webDatabaseName, isNot(b.webDatabaseName));
    expect(a.imageDirectory, isNot(b.imageDirectory));
    expect(() => a.fileKey('../account_profile.json'), throwsArgumentError);
    expect(() => StorageNamespace.account(''), throwsArgumentError);
  });

  test('switch fence drops stale account responses', () async {
    final local = StorageNamespace.local();
    final a = StorageNamespace.account('user-a');
    final b = StorageNamespace.account('user-b');
    final manager = StorageNamespaceManager();
    final calls = <String>[];
    final oldGeneration = manager.generation;

    await manager.switchTo(
      a,
      stopAndFlush: () async => calls.add('close-local'),
      open: (target) async => calls.add(target.relativePath),
    );
    final accountGeneration = manager.generation;
    expect(manager.accepts(local, oldGeneration), isFalse);
    await manager.switchTo(
      b,
      stopAndFlush: () async => calls.add('close-a'),
      open: (target) async => calls.add(target.relativePath),
    );
    expect(manager.accepts(a, accountGeneration), isFalse);
    expect(manager.current, b);
    expect(calls, hasLength(4));
  });

  test('failed opening never publishes the target namespace', () async {
    final manager = StorageNamespaceManager();
    final old = manager.generation;
    await expectLater(
      manager.switchTo(
        StorageNamespace.account('user-a'),
        stopAndFlush: () async {},
        open: (_) async => throw StateError('disk full'),
      ),
      throwsStateError,
    );
    expect(manager.current, StorageNamespace.local());
    expect(manager.isActive, isFalse);
    expect(manager.accepts(StorageNamespace.local(), old), isFalse);
    await manager.switchTo(
      StorageNamespace.local(),
      stopAndFlush: () async {},
      open: (_) async {},
    );
    expect(manager.isActive, isTrue);
  });
}
