import 'dart:async';

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

  test('Local to A to B to A to Local fences stale HTTP callbacks', () async {
    final manager = StorageNamespaceManager();
    final local = StorageNamespace.local();
    final a = StorageNamespace.account('account-a');
    final b = StorageNamespace.account('account-b');
    final stores = <StorageNamespace, Map<String, String>>{
      local: {'outbox': 'local-pending', 'token': ''},
      a: {'outbox': 'a-pending', 'token': 'a-secret'},
      b: {'outbox': 'b-pending', 'token': 'b-secret'},
    };
    final abandoned = <bool Function()>[];
    final visited = <StorageNamespace>[];
    final localGeneration = manager.generation;
    expect(manager.accepts(local, localGeneration), isTrue);

    for (final target in [a, b, a, local]) {
      final from = manager.current;
      final generation = manager.generation;
      abandoned.add(() => manager.accepts(from, generation));
      await manager.switchTo(
        target,
        stopAndFlush: () async {
          expect(stores[from], isNotNull);
          expect(manager.accepts(from, generation), isFalse);
        },
        open: (namespace) async {
          visited.add(namespace);
          expect(stores[namespace], isNotNull);
        },
      );
      expect(manager.accepts(target, manager.generation), isTrue);
      expect(stores[a]!['outbox'], 'a-pending');
      expect(stores[b]!['outbox'], 'b-pending');
      expect(stores[local]!['outbox'], 'local-pending');
    }
    expect(visited, [a, b, a, local]);
    expect(abandoned.every((isCurrent) => !isCurrent()), isTrue);
  });

  test(
    'concurrent switch operations serialize and reject old generation',
    () async {
      final manager = StorageNamespaceManager();
      final a = StorageNamespace.account('A');
      final b = StorageNamespace.account('B');
      final flushed = Completer<void>();
      final release = Completer<void>();
      final first = manager.switchTo(
        a,
        stopAndFlush: () async {
          flushed.complete();
          await release.future;
        },
        open: (_) async {},
      );
      await flushed.future;
      final initial = manager.generation;
      final second = manager.switchTo(
        b,
        stopAndFlush: () async {},
        open: (_) async {},
      );
      expect(manager.accepts(StorageNamespace.local(), initial), isFalse);
      release.complete();
      await Future.wait([first, second]);
      expect(manager.current, b);
      expect(manager.isActive, isTrue);
      expect(manager.accepts(a, manager.generation), isFalse);
    },
  );
}
