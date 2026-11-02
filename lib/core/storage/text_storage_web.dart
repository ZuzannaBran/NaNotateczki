import 'package:web/web.dart' as web;

Future<String?> readStoredText(String key, {String? directoryPath}) async {
  return web.window.localStorage.getItem(key);
}

Future<void> writeStoredText(
  String key,
  String value, {
  String? directoryPath,
}) async {
  web.window.localStorage.setItem(key, value);
}

/// Web writes finish synchronously in localStorage.
Future<void> waitForPendingTextStorageOperations() async {}
