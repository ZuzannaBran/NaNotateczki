import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/input/ink_activity_tracker.dart';
import 'package:uuid/uuid.dart';

import '../../core/error/app_error_log.dart';
import '../../core/storage/text_storage.dart';
import '../sync/account_session_controller.dart';
import 'remote_backup_service.dart';

class RemoteBackupScheduler extends ChangeNotifier with WidgetsBindingObserver {
  RemoteBackupScheduler({
    required this.service,
    required this.session,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_sessionChanged);
    _dirty = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  static const defaultIdleSeconds = 120;
  static const supportedIdleSeconds = <int>[30, 120, 300, 900, 1800];
  static const failureRetry = Duration(minutes: 5);

  final RemoteBackupService service;
  final AccountSessionController session;
  final DateTime Function() _now;
  Timer? _timer;
  late DateTime _lastActivityAt = _now();
  DateTime? _retryNotBefore;
  int _idleSeconds = defaultIdleSeconds;
  int _preferenceGeneration = 0;
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
  int get idleSeconds => _idleSeconds;

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
    _lastActivityAt = _now();
    _retryNotBefore = null;
    _scheduleIdle();
    unawaited(_loadPreference(userId));
    notifyListeners();
  }

  void disable() {
    _enabled = false;
    _timer?.cancel();
    _timer = null;
    _clearAccountState();
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> stop() async {
    disable();
    await _activeUpload;
  }

  void markDirty() {
    _dirty = true;
    _changeGeneration++;
    _recordActivity();
    _scheduleIdle();
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Reloads an account setting received from another signed-in device.
  Future<void> refreshAccountPreference() async {
    final id = _accountUserId;
    if (!_enabled || id == null) {
      return;
    }
    _preferenceGeneration++;
    await _loadPreference(id);
  }

  Future<void> setIdleSeconds(int seconds) async {
    if (!supportedIdleSeconds.contains(seconds)) {
      throw ArgumentError.value(seconds, 'seconds', 'Unsupported idle delay');
    }
    final userId = _accountUserId;
    if (userId == null || !_enabled) {
      throw StateError('Sign in before setting a backup delay.');
    }
    _idleSeconds = seconds;
    _preferenceGeneration++;
    _scheduleIdle();
    notifyListeners();
    await writeStoredText(
      _preferenceKey(userId),
      jsonEncode({'version': 1, 'idleSeconds': seconds}),
    );
    markDirty();
  }

  Future<void> uploadNow({bool manual = false}) {
    final running = _activeUpload;
    if (running != null) {
      return running;
    }
    final future = _uploadNow(manual: manual);
    _activeUpload = future;
    return future.whenComplete(() {
      if (identical(_activeUpload, future)) {
        _activeUpload = null;
      }
    });
  }

  Future<void> backupNow() {
    markDirty();
    return uploadNow(manual: true);
  }

  Future<void> _uploadNow({required bool manual}) async {
    if (!_enabled || !session.isSignedIn || !_dirty || _uploading) {
      return;
    }
    final accountUserId = _accountUserId;
    if (accountUserId == null || accountUserId != session.userId) {
      disable();
      return;
    }
    if (!manual && !_canUploadAutomatically) {
      _scheduleIdle();
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
        _retryNotBefore = null;
        _dirty = _changeGeneration != uploadGeneration;
      }
    } catch (error, stackTrace) {
      if (_accountUserId == accountUserId) {
        lastError = error.toString();
        _dirty = true;
        _retryNotBefore = _now().add(failureRetry);
      }
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'RemoteBackupScheduler.uploadNow',
      );
    } finally {
      _uploading = false;
      if (_dirty && _enabled && session.isSignedIn) {
        _scheduleIdle();
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
      _scheduleIdle();
    }
  }

  bool get _canUploadAutomatically {
    if (InkActivityTracker.instance.isBusy) {
      return false;
    }
    if (_retryNotBefore != null && _now().isBefore(_retryNotBefore!)) {
      return false;
    }
    return _now().difference(_lastActivityAt) >=
        Duration(seconds: _idleSeconds);
  }

  void _recordActivity() {
    if (_enabled && !_disposed) {
      _lastActivityAt = _now();
    }
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent ||
        event is PointerSignalEvent ||
        (event is PointerMoveEvent && event.buttons != 0)) {
      _recordActivity();
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _recordActivity();
    }
    return false;
  }

  void _scheduleIdle() {
    _timer?.cancel();
    _timer = null;
    if (!_enabled || !_dirty || _uploading || _disposed) {
      return;
    }
    final now = _now();
    final idleRemaining =
        Duration(seconds: _idleSeconds) - now.difference(_lastActivityAt);
    final retryRemaining = _retryNotBefore == null
        ? Duration.zero
        : _retryNotBefore!.difference(now);
    var delay = idleRemaining > retryRemaining ? idleRemaining : retryRemaining;
    if (delay < Duration.zero) {
      delay = Duration.zero;
    }
    if (InkActivityTracker.instance.isBusy && delay == Duration.zero) {
      delay = const Duration(seconds: 2);
    }
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(uploadNow());
    });
  }

  String _preferenceKey(String userId) {
    final suffix = sha256
        .convert(utf8.encode(userId))
        .toString()
        .substring(0, 16);
    return 'server_backup_preferences_$suffix.json';
  }

  Future<void> _loadPreference(String userId) async {
    final generation = _preferenceGeneration;
    try {
      final stored = await readStoredText(_preferenceKey(userId));
      if (stored == null) {
        return;
      }
      final decoded = jsonDecode(stored);
      if (decoded is Map<String, dynamic> &&
          decoded['version'] == 1 &&
          supportedIdleSeconds.contains(decoded['idleSeconds']) &&
          !_disposed &&
          generation == _preferenceGeneration &&
          _accountUserId == userId) {
        _idleSeconds = decoded['idleSeconds'] as int;
        _scheduleIdle();
        notifyListeners();
      }
    } catch (error, stackTrace) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'RemoteBackupScheduler.loadPreference',
      );
    }
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
    _idleSeconds = defaultIdleSeconds;
    _retryNotBefore = null;
    _preferenceGeneration++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _enabled &&
        _dirty &&
        session.isSignedIn) {
      _recordActivity();
      _scheduleIdle();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    session.removeListener(_sessionChanged);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
