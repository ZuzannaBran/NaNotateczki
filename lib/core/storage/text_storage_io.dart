import 'dart:async';
import 'dart:io';

import 'app_data_directory.dart';

final Map<String, Future<void>> _operationTails = <String, Future<void>>{};

/// Waits for native storage operations already queued by callers.
Future<void> waitForPendingTextStorageOperations() async {
  while (_operationTails.isNotEmpty) {
    await Future.wait(_operationTails.values.toList());
  }
}

Future<T> _withStorageLock<T>(
  String key, {
  required String? directoryPath,
  required Future<T> Function() action,
}) async {
  final operationKey = directoryPath == null
      ? 'default:$key'
      : '${Directory(directoryPath).absolute.path}/$key';
  final previous = _operationTails[operationKey] ?? Future<void>.value();
  final completion = Completer<void>();
  _operationTails[operationKey] = completion.future;
  try {
    await previous;
    return await action();
  } finally {
    completion.complete();
    if (identical(_operationTails[operationKey], completion.future)) {
      _operationTails.remove(operationKey);
    }
  }
}

Future<String?> readStoredText(String key, {String? directoryPath}) {
  return _withStorageLock(
    key,
    directoryPath: directoryPath,
    action: () async {
      final file = await _fileForKey(key, directoryPath: directoryPath);
      await _recoverAtomicWrite(file);
      if (!await file.exists()) {
        return null;
      }
      return file.readAsString();
    },
  );
}

Future<void> writeStoredText(
  String key,
  String value, {
  String? directoryPath,
}) {
  return _withStorageLock(
    key,
    directoryPath: directoryPath,
    action: () async {
      final file = await _fileForKey(key, directoryPath: directoryPath);
      await _atomicWriteString(file, value);
    },
  );
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

Future<File> _fileForKey(String key, {String? directoryPath}) async {
  // The identity profile is global so a restart can choose its namespace.
  final path =
      directoryPath ??
      (key.startsWith('account_profile.json')
          ? await getRootAppDataPath()
          : await getAppDataPath());
  if (key.startsWith('/') ||
      key.contains('\\') ||
      key
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw ArgumentError.value(key, 'key', 'Invalid relative storage key');
  }
  final file = File('$path/$key');
  await file.parent.create(recursive: true);
  return file;
}
