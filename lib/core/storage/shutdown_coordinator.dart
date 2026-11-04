import 'dart:async';

/// Stages of a bounded, non-destructive account shutdown.
enum ShutdownPhase {
  idle,
  flushLocal,
  syncRemote,
  verifyBackup,
  stopServices,
  endSession,
  complete,
}

/// A timeout never implies that local data or the outbox may be discarded.
class ShutdownInterrupted implements Exception {
  const ShutdownInterrupted(this.phase, this.localSafe, this.reason);

  final ShutdownPhase phase;
  final bool localSafe;
  final Object reason;

  @override
  String toString() =>
      'Shutdown stopped at ' +
      phase.name +
      ' (localSafe: ' +
      localSafe.toString() +
      '): ' +
      reason.toString();
}

/// Shared by explicit logout and the desktop window-close guard.
///
/// Callers must keep the current account active if [run] fails. In particular,
/// an offline logout is permitted only after [flushLocal] has completed.
/// Network operations that timed out must be stopped/joined before switching
/// to another database or clearing the account credentials.
class ShutdownCoordinator {
  ShutdownCoordinator({
    required this.flushLocal,
    this.syncRemote,
    this.verifyBackup,
    this.stopServices,
    this.endSession,
    this.onPhase,
    this.timeout = const Duration(seconds: 30),
  });

  final Future<void> Function() flushLocal;
  final Future<void> Function()? syncRemote;
  final Future<void> Function()? verifyBackup;
  final Future<void> Function()? stopServices;
  final Future<void> Function()? endSession;
  final void Function(ShutdownPhase)? onPhase;
  final Duration timeout;

  ShutdownPhase phase = ShutdownPhase.idle;
  Future<void>? _running;

  Future<void> run({bool preserveOffline = false}) {
    final active = _running;
    if (active != null) {
      return active;
    }
    final attempt = _execute(preserveOffline: preserveOffline);
    _running = attempt;
    attempt.then(
      (_) {
        if (identical(_running, attempt)) {
          _running = null;
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_running, attempt)) {
          _running = null;
        }
      },
    );
    return attempt;
  }

  Future<void> _execute({required bool preserveOffline}) async {
    final stopwatch = Stopwatch()..start();
    var localSafe = false;

    Future<void> step(
      ShutdownPhase next,
      Future<void> Function() operation,
    ) async {
      phase = next;
      onPhase?.call(next);
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw ShutdownInterrupted(next, localSafe, 'Overall timeout');
      }
      try {
        await operation().timeout(remaining);
      } on ShutdownInterrupted {
        rethrow;
      } catch (error) {
        throw ShutdownInterrupted(next, localSafe, error);
      }
    }

    try {
      await step(ShutdownPhase.flushLocal, flushLocal);
      localSafe = true;
      if (!preserveOffline && syncRemote != null) {
        await step(ShutdownPhase.syncRemote, syncRemote!);
      }
      if (!preserveOffline && verifyBackup != null) {
        await step(ShutdownPhase.verifyBackup, verifyBackup!);
      }
      if (stopServices != null) {
        await step(ShutdownPhase.stopServices, stopServices!);
      }
      if (endSession != null) {
        await step(ShutdownPhase.endSession, endSession!);
      }
      phase = ShutdownPhase.complete;
      onPhase?.call(phase);
    } finally {
      stopwatch.stop();
    }
  }
}
