import 'dart:convert';

import 'storage_namespace_manager.dart';

/// Selects a clean Local or account data root for a running AppScope.
/// Credentials and account_profile.json remain outside this namespace.
class ActiveStorageNamespace {
  static StorageNamespace _current = StorageNamespace.local();

  static StorageNamespace get current => _current;

  static void activate(StorageNamespace namespace) {
    _current = namespace;
  }

  static StorageNamespace fromProfile(String? content) {
    if (content == null) {
      return StorageNamespace.local();
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
      throw const FormatException('Invalid account storage profile.');
    }
    if (decoded['preferredMode'] != 'account') {
      return StorageNamespace.local();
    }
    final id = decoded['boundUserId'];
    if (id == null) {
      return StorageNamespace.local();
    }
    if (id is! String ||
        !RegExp(r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')
            .hasMatch(id)) {
      throw const FormatException('Invalid account storage identity.');
    }
    return StorageNamespace.account(id.toLowerCase());
  }
}
