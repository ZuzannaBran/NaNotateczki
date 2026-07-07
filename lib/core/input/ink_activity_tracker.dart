import 'package:flutter/foundation.dart';

class InkActivityTracker extends ChangeNotifier {
  InkActivityTracker._();

  static final InkActivityTracker instance = InkActivityTracker._();
  static const Duration idleDelay = Duration(seconds: 2);

  int _activeContacts = 0;
  DateTime? _busyUntil;

  bool get isBusy {
    final busyUntil = _busyUntil;
    return _activeContacts > 0 ||
        (busyUntil != null && DateTime.now().isBefore(busyUntil));
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
