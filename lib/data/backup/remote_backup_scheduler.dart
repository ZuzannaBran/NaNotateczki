import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../../core/error/app_error_log.dart';
import '../../core/storage/text_storage.dart';
import '../sync/account_session_controller.dart';
import 'remote_backup_service.dart';

class RemoteBackupScheduler extends ChangeNotifier with WidgetsBindingObserver {
  RemoteBackupScheduler({required this.service, required this.session}) {
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_sessionChanged);
    _dirty = true;
  }

  static const interval = Duration(minutes: 30);
  static const failureRetry = Duration(minutes: 5);

  final RemoteBackupService service;
  final AccountSessionController session;
  Timer? _timer;
  bool _dirty = false;
  int _changeGeneration = 0;
  bool _enabled = false;
  bool _uploading = false;
  bool _disposed = false;
  Future<void>? _activeUpload;
  String? _accountUserId;
  RemoteBackupReceipt? lastVerifiedBackup;
  String? lastError;

  bool get isUploading => _uploading;
  bool get hasPendingBackup => _dirty;
  bool get isEnabled => _enabled;

  void enableForSignedInAccount() {
    final userId = session.userId;
    if (!session.isSignedIn || userId == null) {
      throw StateError('Sign in before enabling remote backups.');
    }
    if (_accountUserId != userId) {
      _clearAccountState();
      _accountUserId = userId;
    }
    _enabled = true;
    _dirty = true;
    _changeGeneration++;
    _schedule(const Duration(seconds: 3));
    notifyListeners();
  }

  void disable() {
    _enabled = false;
    _timer?.cancel();
    _timer = null;
    _clearAccountState();
    notifyListeners();
  }

  Future<void> stop() async {
    disable();
    await _activeUpload;
  }

  void markDirty() {
    _dirty = true;
    _changeGeneration++;
    if (_enabled && session.isSignedIn) {
      _schedule(interval);
    }
    notifyListeners();
  }

  Future<void> uploadNow() {
    final running = _activeUpload;
    if (running != null) {
      return running;
    }
    final future = _uploadNow();
    _activeUpload = future;
    return future.whenComplete(() {
      if (identical(_activeUpload, future)) {
        _activeUpload = null;
      }
    });
  }

  Future<void> backupNow() {
    markDirty();
    return uploadNow();
  }

  Future<void> _uploadNow() async {
    if (!_enabled || !session.isSignedIn || !_dirty || _uploading) {
      return;
    }
    final accountUserId = _accountUserId;
    if (accountUserId == null || accountUserId != session.userId) {
      disable();
      return;
    }
    _timer?.cancel();
    _timer = null;
    _uploading = true;
    final uploadGeneration = _changeGeneration;
    notifyListeners();
    try {
      final receipt = await service.uploadVerifiedSnapshot(
        deviceId: await _deviceId(accountUserId),
      );
      if (_accountUserId == accountUserId && session.userId == accountUserId) {
        lastVerifiedBackup = receipt;
        lastError = null;
        _dirty = _changeGeneration != uploadGeneration;
      }
    } catch (error, stackTrace) {
      if (_accountUserId == accountUserId) {
        lastError = error.toString();
        _dirty = true;
      }
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'RemoteBackupScheduler.uploadNow',
      );
    } finally {
      _uploading = false;
      if (_dirty && _enabled && session.isSignedIn) {
        _schedule(lastError == null ? interval : failureRetry);
      }
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _sessionChanged() {
    if (!session.isSignedIn || session.userId != _accountUserId) {
      disable();
      return;
    }
    if (_enabled && _dirty) {
      _schedule(const Duration(seconds: 3));
    }
  }

  void _schedule(Duration delay) {
    if (_timer != null || _uploading || _disposed) {
      return;
    }
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(uploadNow());
    });
  }

  Future<String> _deviceId(String userId) async {
    final suffix = sha256
        .convert(utf8.encode(userId))
        .toString()
        .substring(0, 16);
    final key = 'server_device_$suffix.json';
    final stored = await readStoredText(key);
    if (stored != null) {
      final decoded = jsonDecode(stored);
      if (decoded is Map<String, dynamic> && decoded['deviceId'] is String) {
        final value = decoded['deviceId'] as String;
        if (RegExp(r'^[0-9a-f-]{36}$').hasMatch(value)) {
          return value;
        }
      }
    }
    final value = const Uuid().v4();
    await writeStoredText(key, jsonEncode({'version': 1, 'deviceId': value}));
    return value;
  }

  void _clearAccountState() {
    _accountUserId = null;
    lastVerifiedBackup = null;
    lastError = null;
    _dirty = true;
    _changeGeneration++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _enabled &&
        _dirty &&
        session.isSignedIn) {
      unawaited(uploadNow());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    session.removeListener(_sessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
