import 'dart:async';

import 'api_client.dart';

/// Sends a best-effort wake request at startup and after continued activity.
class AppActivityWakeService {
  AppActivityWakeService({
    required this.apiClient,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const interval = Duration(minutes: 30);

  final ApiClient apiClient;
  final DateTime Function() _now;

  DateTime? _lastAttempt;
  bool _enabled = false;
  bool _foreground = true;
  bool _disposed = false;

  /// Local-only profiles never contact the API.
  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) {
      return;
    }
    _enabled = enabled;
    if (!enabled) {
      _lastAttempt = null;
      return;
    }
    noteActivity();
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
  }

  /// There is no timer: another input event is required after 30 minutes.
  void noteActivity() {
    if (_disposed || !_enabled || !_foreground || !apiClient.isConfigured) {
      return;
    }
    final now = _now();
    final previous = _lastAttempt;
    if (previous != null &&
        !now.isBefore(previous) &&
        now.difference(previous) < interval) {
      return;
    }
    _lastAttempt = now;
    unawaited(_ping());
  }

  Future<void> _ping() async {
    try {
      await apiClient.request(
        'GET',
        '/health',
        authenticated: false,
        requestTimeout: const Duration(seconds: 4),
        maxResponseBytes: 512,
      );
    } catch (_) {
      // A sleeping or disconnected server must not affect the application.
    }
  }

  void dispose() {
    _disposed = true;
  }
}
