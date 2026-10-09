import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class StylusButtonState {
  static const MethodChannel _channel = MethodChannel(
    'nanotateczki/stylus_button',
  );

  static final ValueNotifier<bool> pressed = ValueNotifier<bool>(false);
  static final ValueNotifier<int> eraserToggleRequests = ValueNotifier<int>(0);
  static bool _initialized = false;

  static bool get isPressed => pressed.value;

  static void initialize() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'toggleEraser') {
      eraserToggleRequests.value++;
      return;
    }
    if (call.method != 'setPressed') {
      return;
    }
    final args = call.arguments;
    if (args is! Map) {
      return;
    }
    final value = args['pressed'];
    if (value is bool && pressed.value != value) {
      pressed.value = value;
    }
  }
}
