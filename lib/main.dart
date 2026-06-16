import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/notes_app.dart';
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
  return _wrappedKeyDataHandler?.call(data) ?? false;
}

void main() {
  runZonedGuarded(_runApp, (error, stackTrace) {
    AppErrorLog.instance.record(error, stackTrace, source: 'Dart zone');
  });
}

void _runApp() {
  WidgetsFlutterBinding.ensureInitialized();
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
  return message.contains('hardware_keyboard.dart') &&
      message.contains('data.physical != 0 && data.logical != 0') &&
      stack.contains('KeyEventManager.handleKeyData');
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
