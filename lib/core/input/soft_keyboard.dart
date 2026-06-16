import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'app_preferences_controller.dart';

void requestSoftKeyboardForFocus(BuildContext context, FocusNode focusNode) {
  final preferences = context.read<AppPreferencesController>();
  if (!preferences.shouldRequestSoftKeyboard) {
    return;
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (focusNode.context == null || !focusNode.canRequestFocus) {
      return;
    }
    if (!focusNode.hasFocus) {
      focusNode.requestFocus();
    }
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  });
}
