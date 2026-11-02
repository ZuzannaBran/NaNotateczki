/// Presents a service error once until that service recovers.
class OneShotErrorNotice {
  final Expando<String> _lastSeen = Expando<String>();

  void acknowledge(Object source, String? message) {
    _lastSeen[source] = message;
  }

  bool shouldPresent(Object source, String? message) {
    if (message == null || message.isEmpty) {
      _lastSeen[source] = null;
      return false;
    }
    if (_lastSeen[source] == message) {
      return false;
    }
    _lastSeen[source] = message;
    return true;
  }
}
