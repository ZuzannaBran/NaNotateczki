import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/diagnostics/data_integrity_log.dart';
import '../../core/diagnostics/optimization_log.dart';
import '../../core/error/app_error_log.dart';
import '../../core/storage/text_storage.dart';
import 'account_session_controller.dart';
import 'api_client.dart';

/// Replaces server-side logs for this account/device after changes.
class DiagnosticsUploadService {
  DiagnosticsUploadService({
    required ApiClient apiClient,
    required AccountSessionController session,
  }) : _apiClient = apiClient,
       _session = session {
    AppErrorLog.instance.addListener(_schedule);
    DataIntegrityLog.instance.addListener(_schedule);
    OptimizationLog.instance.addListener(_schedule);
    _session.addListener(_schedule);
    _schedule();
  }

  static const _deviceKey = 'diagnostics_device_id.json';

  final ApiClient _apiClient;
  final AccountSessionController _session;
  Timer? _timer;
  bool _disposed = false;
  bool _uploading = false;
  bool _changedWhileUploading = false;
  String? _lastUploaded;
  String? _lastAccount;

  void _schedule() {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    if (!_session.isSignedIn || _session.isBusy) {
      _lastUploaded = null;
      _lastAccount = null;
      return;
    }
    _timer = Timer(const Duration(seconds: 12), () {
      unawaited(uploadNow());
    });
    if (_uploading) {
      _changedWhileUploading = true;
    }
  }

  Future<String> _getDeviceId() async {
    final previous = await readStoredText(_deviceKey);
    if (previous != null &&
        RegExp(
          r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
        ).hasMatch(previous)) {
      return previous;
    }
    final id = const Uuid().v4();
    await writeStoredText(_deviceKey, id);
    return id;
  }

  String _logText(bool empty, String text) {
    if (empty) {
      return '';
    }
    return text.length <= 30000 ? text : text.substring(0, 30000);
  }

  Future<void> uploadNow() async {
    if (_disposed || !_session.isSignedIn || _session.isBusy) {
      return;
    }
    if (_uploading) {
      _changedWhileUploading = true;
      return;
    }
    _uploading = true;
    try {
      final account = _session.userId;
      final deviceId = await _getDeviceId();
      if (_disposed || !_session.isSignedIn || _session.userId != account) {
        return;
      }
      final payload = <String, Object>{
        'deviceId': deviceId,
        'system': _currentSystem(),
        'errors': _logText(
          AppErrorLog.instance.isEmpty,
          AppErrorLog.instance.toClipboardText(),
        ),
        'dataIntegrity': _logText(
          DataIntegrityLog.instance.isEmpty,
          DataIntegrityLog.instance.toClipboardText(),
        ),
        'optimization': _logText(
          OptimizationLog.instance.isEmpty,
          OptimizationLog.instance.toClipboardText(),
        ),
      };
      final encoded = jsonEncode(payload);
      if (_lastAccount == account && _lastUploaded == encoded) {
        return;
      }
      await _apiClient.putJson('/v1/reports/diagnostics', payload);
      if (_session.userId == account && !_disposed) {
        _lastAccount = account;
        _lastUploaded = encoded;
      }
    } catch (_) {
      // A failed report must never block the editor, backup or synchronization.
      if (!_disposed && _session.isSignedIn) {
        _timer?.cancel();
        _timer = Timer(const Duration(minutes: 5), () {
          unawaited(uploadNow());
        });
      }
    } finally {
      _uploading = false;
      if (_changedWhileUploading) {
        _changedWhileUploading = false;
        _schedule();
      }
    }
  }

  String _currentSystem() {
    if (kIsWeb) {
      return 'Web';
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.fuchsia => 'Other',
    };
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    AppErrorLog.instance.removeListener(_schedule);
    DataIntegrityLog.instance.removeListener(_schedule);
    OptimizationLog.instance.removeListener(_schedule);
    _session.removeListener(_schedule);
  }
}
