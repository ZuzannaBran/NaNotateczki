import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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

  bool get shouldRequestSoftKeyboard {
    return deviceInputMode == DeviceInputMode.tablet;
  }

  Future<void> load() async {
    try {
      final file = await _prefsFile();
      if (!await file.exists()) {
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final modeIndex = decoded['deviceInputMode'];
      if (modeIndex is int &&
          modeIndex >= 0 &&
          modeIndex < DeviceInputMode.values.length) {
        deviceInputMode = DeviceInputMode.values[modeIndex];
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

  Future<void> _save() async {
    try {
      final file = await _prefsFile();
      await file.writeAsString(
        jsonEncode({'deviceInputMode': deviceInputMode.index}),
      );
    } catch (e) {
      debugPrint('AppPreferencesController._save failed: $e');
    }
  }

  Future<File> _prefsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }
}

DeviceInputMode _defaultDeviceInputMode() {
  if (Platform.isAndroid || Platform.isIOS) {
    return DeviceInputMode.tablet;
  }
  return DeviceInputMode.computer;
}
