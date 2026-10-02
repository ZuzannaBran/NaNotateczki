import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/text_storage.dart';
import '../theme/app_colors.dart';

enum DeviceInputMode { computer, tablet }

extension DeviceInputModeX on DeviceInputMode {
  String get label {
    return switch (this) {
      DeviceInputMode.computer => 'Computer',
      DeviceInputMode.tablet => 'Tablet',
    };
  }

  String get description {
    return switch (this) {
      DeviceInputMode.computer => 'Use the normal hardware keyboard behavior.',
      DeviceInputMode.tablet =>
        'Request the system on-screen keyboard for text fields.',
    };
  }
}

class AppPreferencesController extends ChangeNotifier {
  static const _fileName = 'app_prefs.json';

  DeviceInputMode deviceInputMode = _defaultDeviceInputMode();
  AppAccentColor accentColor = AppAccentColor.classic;

  bool get shouldRequestSoftKeyboard {
    return deviceInputMode == DeviceInputMode.tablet;
  }

  Future<void> load() async {
    try {
      final content = await readStoredText(_fileName);
      if (content == null) {
        return;
      }
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      var changed = false;
      final modeIndex = decoded['deviceInputMode'];
      if (modeIndex is int &&
          modeIndex >= 0 &&
          modeIndex < DeviceInputMode.values.length) {
        final loadedMode = DeviceInputMode.values[modeIndex];
        if (loadedMode != deviceInputMode) {
          deviceInputMode = loadedMode;
          changed = true;
        }
      }

      final accentIndex = decoded['accentColor'];
      if (accentIndex is int &&
          accentIndex >= 0 &&
          accentIndex < AppAccentColor.values.length) {
        final loadedAccent = AppAccentColor.values[accentIndex];
        if (loadedAccent != accentColor) {
          accentColor = loadedAccent;
          changed = true;
        }
      }

      if (changed) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('AppPreferencesController.load failed: $e');
    }
  }

  Future<void> setDeviceInputMode(DeviceInputMode mode) async {
    if (deviceInputMode == mode) {
      return;
    }
    deviceInputMode = mode;
    notifyListeners();
    await _save();
  }

  Future<void> setAccentColor(AppAccentColor color) async {
    if (accentColor == color) {
      return;
    }
    accentColor = color;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      await writeStoredText(
        _fileName,
        jsonEncode({
          'deviceInputMode': deviceInputMode.index,
          'accentColor': accentColor.index,
        }),
      );
    } catch (e) {
      debugPrint('AppPreferencesController._save failed: $e');
    }
  }
}

DeviceInputMode _defaultDeviceInputMode() {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return DeviceInputMode.tablet;
  }
  return DeviceInputMode.computer;
}
