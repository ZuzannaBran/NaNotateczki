import 'package:web/web.dart' as web;

import 'active_storage_namespace.dart';

String _scopedKey(String key) => key.startsWith('account_profile.json')
    ? key
    : '${ActiveStorageNamespace.current.relativePath}/$key';

Future<String?> readStoredText(String key, {String? directoryPath}) async {
  return web.window.localStorage.getItem(_scopedKey(key));
}

Future<void> writeStoredText(
  String key,
  String value, {
  String? directoryPath,
}) async {
  web.window.localStorage.setItem(_scopedKey(key), value);
}

/// Web writes finish synchronously in localStorage.
Future<void> waitForPendingTextStorageOperations() async {}
