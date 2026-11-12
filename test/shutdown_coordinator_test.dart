import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/shutdown_coordinator.dart';

void main() {
  test('flushes before sync and verified backup', () async {
    final order = <String>[];
    final coordinator = ShutdownCoordinator(
      flushLocal: () async {
        order.add('local');
      },
      syncRemote: () async {
        order.add('sync');
      },
      verifyBackup: () async {
        order.add('backup');
      },
    );
    await coordinator.run();
    expect(order, ['local', 'sync', 'backup']);
    expect(coordinator.phase, ShutdownPhase.complete);
  });

  test('offline mode never touches network or backup', () async {
    final order = <String>[];
    final coordinator = ShutdownCoordinator(
      flushLocal: () async => order.add('local'),
      syncRemote: () async => order.add('sync'),
      verifyBackup: () async => order.add('backup'),
    );
    await coordinator.run(preserveOffline: true);
    expect(order, ['local']);
  });

  test('local write failure forbids offline logout', () async {
    final coordinator = ShutdownCoordinator(
      flushLocal: () async => throw StateError('disk full'),
    );
    await expectLater(
      coordinator.run(preserveOffline: true),
      throwsA(
        isA<ShutdownInterrupted>()
            .having((e) => e.phase, 'phase', ShutdownPhase.flushLocal)
            .having((e) => e.localSafe, 'local safe', false),
      ),
    );
  });

  test('network failure preserves already durable local work', () async {
    final coordinator = ShutdownCoordinator(
      flushLocal: () async {},
      syncRemote: () async => throw StateError('offline'),
    );
    await expectLater(
      coordinator.run(),
      throwsA(
        isA<ShutdownInterrupted>()
            .having((e) => e.phase, 'phase', ShutdownPhase.syncRemote)
            .having((e) => e.localSafe, 'local safe', true),
      ),
    );
    await coordinator.run(preserveOffline: true);
  });

  test('global timeout applies to network', () async {
    final gate = Completer<void>();
    final coordinator = ShutdownCoordinator(
      timeout: const Duration(milliseconds: 15),
      flushLocal: () async {},
      syncRemote: () => gate.future,
    );
    await expectLater(
      coordinator.run(),
      throwsA(
        isA<ShutdownInterrupted>()
            .having((e) => e.phase, 'phase', ShutdownPhase.syncRemote)
            .having((e) => e.localSafe, 'local safe', true),
      ),
    );
    gate.complete();
  });

  test('offline logout stops services after local writes', () async {
    final order = <String>[];
    final coordinator = ShutdownCoordinator(
      flushLocal: () async {
        order.add('flush');
      },
      syncRemote: () async {
        order.add('network');
      },
      stopServices: () async {
        order.add('stop');
      },
      endSession: () async {
        order.add('signout');
      },
    );
    await coordinator.run(preserveOffline: true);
    expect(order, ['flush', 'stop', 'signout']);
  });

  test('service stop failure prevents credential clearing', () async {
    var loggedOut = false;
    final coordinator = ShutdownCoordinator(
      flushLocal: () async {},
      stopServices: () async {
        throw StateError('network writer still active');
      },
      endSession: () async {
        loggedOut = true;
      },
    );
    await expectLater(
      coordinator.run(preserveOffline: true),
      throwsA(
        isA<ShutdownInterrupted>()
            .having((e) => e.phase, 'phase', ShutdownPhase.stopServices)
            .having((e) => e.localSafe, 'local safe', true),
      ),
    );
    expect(loggedOut, isFalse);
  });

  test('reports each stage and forbids signout after stop timeout', () async {
    final stages = <ShutdownPhase>[];
    final pendingStop = Completer<void>();
    var clearedCredentials = false;
    final coordinator = ShutdownCoordinator(
      timeout: const Duration(milliseconds: 15),
      flushLocal: () async {},
      syncRemote: () async {},
      verifyBackup: () async {},
      stopServices: () => pendingStop.future,
      endSession: () async {
        clearedCredentials = true;
      },
      onPhase: stages.add,
    );
    await expectLater(
      coordinator.run(),
      throwsA(
        isA<ShutdownInterrupted>()
            .having((e) => e.phase, 'phase', ShutdownPhase.stopServices)
            .having((e) => e.localSafe, 'durable', true),
      ),
    );
    expect(clearedCredentials, isFalse);
    expect(stages, [
      ShutdownPhase.flushLocal,
      ShutdownPhase.syncRemote,
      ShutdownPhase.verifyBackup,
      ShutdownPhase.stopServices,
    ]);
    pendingStop.complete();
  });

  test('concurrent runs reuse one shutdown attempt', () async {
    final gate = Completer<void>();
    var calls = 0;
    final coordinator = ShutdownCoordinator(
      flushLocal: () {
        calls++;
        return gate.future;
      },
    );
    final first = coordinator.run();
    final second = coordinator.run(preserveOffline: true);
    expect(identical(first, second), isTrue);
    gate.complete();
    await Future.wait([first, second]);
    expect(calls, 1);
  });
}
