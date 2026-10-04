import 'dart:async';

import 'package:flutter/foundation.dart';

class InkActivityTracker extends ChangeNotifier {
  InkActivityTracker._();

  static final InkActivityTracker instance = InkActivityTracker._();
  static const Duration idleDelay = Duration(seconds: 2);

  int _activeContacts = 0;
  DateTime? _busyUntil;

  bool get hasActiveContacts => _activeContacts > 0;

  bool get isBusy {
    final busyUntil = _busyUntil;
    return hasActiveContacts ||
        (busyUntil != null && DateTime.now().isBefore(busyUntil));
  }

  Future<void> waitForNoActiveContacts() async {
    if (!hasActiveContacts) {
      return;
    }

    final completer = Completer<void>();
    void listener() {
      if (!hasActiveContacts && !completer.isCompleted) {
        completer.complete();
      }
    }

    addListener(listener);
    try {
      listener();
      await completer.future;
    } finally {
      removeListener(listener);
    }
  }

  void beginContact() {
    _busyUntil = null;
    _activeContacts++;
    notifyListeners();
  }

  void endContact() {
    if (_activeContacts == 0) {
      return;
    }
    _activeContacts--;
    if (_activeContacts > 0) {
      return;
    }
    _busyUntil = DateTime.now().add(idleDelay);
    notifyListeners();
  }
}
