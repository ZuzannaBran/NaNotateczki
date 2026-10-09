import 'package:web/web.dart' as web;

Future<String?> readStoredText(String key) async {
  return web.window.localStorage.getItem(key);
}

Future<void> writeStoredText(String key, String value) async {
  web.window.localStorage.setItem(key, value);
}
