import 'package:flutter/material.dart';

import 'app/notes_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final existingKeyDataHandler = dispatcher.onKeyData;
  dispatcher.onKeyData = (data) {
    // Drop invalid key packets that trigger framework assertions on Linux.
    if (data.physical == 0 || data.logical == 0) {
      return false;
    }
    return existingKeyDataHandler?.call(data) ?? false;
  };
  runApp(const NotesApp());
}
