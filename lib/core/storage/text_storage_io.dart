import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

final Map<String, Future<void>> _writeTails = <String, Future<void>>{};

Future<String?> readStoredText(String key) async {
  final pendingWrite = _writeTails[key];
  if (pendingWrite != null) {
    await pendingWrite;
  }
  final file = await _fileForKey(key);
  await _recoverAtomicWrite(file);
  if (!await file.exists()) {
    return null;
  }
  return file.readAsString();
}

Future<void> writeStoredText(String key, String value) async {
  final previous = _writeTails[key] ?? Future<void>.value();
  final completion = Completer<void>();
  _writeTails[key] = completion.future;
  try {
    await previous;
    final file = await _fileForKey(key);
    await _atomicWriteString(file, value);
  } finally {
    completion.complete();
    if (identical(_writeTails[key], completion.future)) {
      _writeTails.remove(key);
    }
  }
}

Future<void> _atomicWriteString(File file, String content) async {
  await _recoverAtomicWrite(file);
  final temporary = File('${file.path}.tmp');
  final previous = File('${file.path}.previous');
  if (await temporary.exists()) {
    await temporary.delete();
  }
  if (await previous.exists()) {
    await previous.delete();
  }

  await temporary.writeAsString(content, flush: true);
  if (await file.exists()) {
    await file.rename(previous.path);
  }
  try {
    await temporary.rename(file.path);
    if (await previous.exists()) {
      await previous.delete();
    }
  } catch (_) {
    if (!await file.exists() && await previous.exists()) {
      await previous.rename(file.path);
    }
    rethrow;
  }
}

Future<void> _recoverAtomicWrite(File file) async {
  final temporary = File('${file.path}.tmp');
  final previous = File('${file.path}.previous');
  if (!await file.exists() && await previous.exists()) {
    await previous.rename(file.path);
  } else if (await previous.exists()) {
    await previous.delete();
  }
  if (await temporary.exists()) {
    await temporary.delete();
  }
}

Future<File> _fileForKey(String key) async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/$key');
}
