import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<String?> readStoredText(String key) async {
  final file = await _fileForKey(key);
  if (!await file.exists()) {
    return null;
  }
  return file.readAsString();
}

Future<void> writeStoredText(String key, String value) async {
  final file = await _fileForKey(key);
  await file.writeAsString(value);
}

Future<File> _fileForKey(String key) async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/$key');
}
