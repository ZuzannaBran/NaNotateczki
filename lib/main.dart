import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/notes_app.dart';
import 'core/diagnostics/data_integrity_log.dart';
import 'core/diagnostics/optimization_log.dart';
import 'core/error/app_error_log.dart';
import 'core/input/stylus_button_state.dart';

ui.KeyDataCallback? _wrappedKeyDataHandler;
ui.ErrorCallback? _wrappedPlatformErrorHandler;
Timer? _keyDataFilterWatchdog;
int _keyDataFilterWatchdogTicks = 0;
void Function(FlutterErrorDetails details)? _wrappedFlutterErrorHandler;

bool _invalidKeyDataFilter(ui.KeyData data) {
  if (data.physical == 0 || data.logical == 0) {
    return true;
  }
  try {
    return _wrappedKeyDataHandler?.call(data) ?? false;
  } on AssertionError catch (error, stackTrace) {
    if (_isRawKeyDataTransitAssertion(error, stackTrace)) {
      return true;
    }
    rethrow;
  }
}

void main() {
  runZonedGuarded(
    () async {
      await _runApp();
    },
    (error, stackTrace) {
      AppErrorLog.instance.record(error, stackTrace, source: 'Dart zone');
    },
  );
}

Future<void> _runApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppErrorLog.instance.load();
  await DataIntegrityLog.instance.load();
  await OptimizationLog.instance.load();
  _installFlutterErrorLogger();
  StylusButtonState.initialize();
  _installInvalidKeyDataFilter();
  _installInvalidKeyDataErrorFilter();
  unawaited(
    ServicesBinding.instance.keyboard.syncKeyboardState().whenComplete(
      _installInvalidKeyDataFilter,
    ),
  );
  _startKeyDataFilterWatchdog();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _installInvalidKeyDataFilter();
  });
  runApp(const NotesApp());
}

void _installFlutterErrorLogger() {
  final currentHandler = FlutterError.onError;
  if (currentHandler == _flutterErrorLogger) {
    return;
  }
  _wrappedFlutterErrorHandler = currentHandler;
  FlutterError.onError = _flutterErrorLogger;
}

void _flutterErrorLogger(FlutterErrorDetails details) {
  if (_isDuplicatePointerAddedAssertion(details)) {
    return;
  }
  AppErrorLog.instance.recordFlutterError(details);
  _wrappedFlutterErrorHandler?.call(details);
}

void _installInvalidKeyDataFilter() {
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final currentKeyDataHandler = dispatcher.onKeyData;
  if (currentKeyDataHandler == _invalidKeyDataFilter) {
    return;
  }
  _wrappedKeyDataHandler = currentKeyDataHandler;
  dispatcher.onKeyData = _invalidKeyDataFilter;
}

void _installInvalidKeyDataErrorFilter() {
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final currentErrorHandler = dispatcher.onError;
  if (currentErrorHandler == _invalidKeyDataErrorFilter) {
    return;
  }
  _wrappedPlatformErrorHandler = currentErrorHandler;
  dispatcher.onError = _invalidKeyDataErrorFilter;
}

bool _invalidKeyDataErrorFilter(Object error, StackTrace stackTrace) {
  if (_isInvalidKeyDataAssertion(error, stackTrace)) {
    _installInvalidKeyDataFilter();
    return true;
  }
  AppErrorLog.instance.record(error, stackTrace, source: 'Platform dispatcher');
  return _wrappedPlatformErrorHandler?.call(error, stackTrace) ?? false;
}

bool _isInvalidKeyDataAssertion(Object error, StackTrace stackTrace) {
  final message = error.toString();
  final stack = stackTrace.toString();
  if (!message.contains('hardware_keyboard.dart') ||
      !stack.contains('KeyEventManager.handleKeyData')) {
    return false;
  }
  return message.contains('data.physical != 0 && data.logical != 0') ||
      message.contains(
        'Should never encounter KeyData when transitMode is rawKeyData',
      );
}

bool _isRawKeyDataTransitAssertion(Object error, StackTrace stackTrace) {
  return error.toString().contains(
        'Should never encounter KeyData when transitMode is rawKeyData',
      ) &&
      stackTrace.toString().contains('KeyEventManager.handleKeyData');
}

bool _isDuplicatePointerAddedAssertion(FlutterErrorDetails details) {
  final message = details.exceptionAsString();
  final stack = details.stack?.toString() ?? '';
  return message.contains('mouse_tracker.dart') &&
      message.contains(
        '(event is PointerAddedEvent) == '
        '(lastEvent is PointerRemovedEvent)',
      ) &&
      stack.contains('MouseTracker._shouldMarkStateDirty');
}

void _startKeyDataFilterWatchdog() {
  _keyDataFilterWatchdog?.cancel();
  _keyDataFilterWatchdogTicks = 0;
  _keyDataFilterWatchdog = Timer.periodic(const Duration(milliseconds: 500), (
    timer,
  ) {
    _installInvalidKeyDataFilter();
    _keyDataFilterWatchdogTicks += 1;
    if (_keyDataFilterWatchdogTicks >= 7200) {
      timer.cancel();
      if (identical(_keyDataFilterWatchdog, timer)) {
        _keyDataFilterWatchdog = null;
      }
    }
  });
}
