import 'storage_namespace_manager.dart';
import 'text_storage_io.dart'
    if (dart.library.js_interop) 'text_storage_web.dart'
    as platform;

/// Overrides for tests that exercise UI without depending on physical I/O.
Future<String?> Function(String key)? textStorageReadOverride;
Future<void> Function(String key, String value)? textStorageWriteOverride;

Future<String?> readStoredText(String key, {String? directoryPath}) {
  final override = directoryPath == null ? textStorageReadOverride : null;
  return override != null
      ? override(key)
      : platform.readStoredText(key, directoryPath: directoryPath);
}

Future<void> writeStoredText(
  String key,
  String value, {
  String? directoryPath,
}) {
  final override = directoryPath == null ? textStorageWriteOverride : null;
  return override != null
      ? override(key, value)
      : platform.writeStoredText(key, value, directoryPath: directoryPath);
}

/// Reads another isolated store without changing the active identity.
Future<String?> readStoredTextForNamespace(
  StorageNamespace namespace,
  String key,
) => platform.readStoredTextForNamespace(namespace, key);

/// Waits for queued native storage operations to finish.
Future<void> waitForPendingTextStorageOperations() =>
    platform.waitForPendingTextStorageOperations();
