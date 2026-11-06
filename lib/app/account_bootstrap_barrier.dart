import 'dart:async';

/// Invalidates pending account startup before draining its writers.
class AccountBootstrapBarrier {
  int _generation = 0;
  bool _disposed = false;
  Future<void>? _quiescence;

  int get generation => _generation;
  bool get canStart => !_disposed && _quiescence == null;
  bool isCurrent(int generation) => canStart && generation == _generation;

  Future<void> quiesce(Future<void> Function() drain) {
    if (_disposed) {
      return Future<void>.error(StateError('Account startup is disposed.'));
    }
    final running = _quiescence;
    if (running != null) {
      return running;
    }
    final completion = Completer<void>();
    late final Future<void> settled;
    settled = completion.future.whenComplete(() {
      if (identical(_quiescence, settled)) {
        _quiescence = null;
        // A ticket observed while draining must not become current later.
        ++_generation;
      }
    });
    _quiescence = settled;
    ++_generation;
    unawaited(
      Future<void>.sync(drain).then<void>(
        (_) => completion.complete(),
        onError: (Object error, StackTrace stack) {
          completion.completeError(error, stack);
        },
      ),
    );
    return settled;
  }

  void dispose() {
    _disposed = true;
    ++_generation;
  }
}
