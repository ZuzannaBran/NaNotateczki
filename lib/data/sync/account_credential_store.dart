import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists refresh credentials outside the ordinary application data files.
abstract class AccountCredentialStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Uses the platform keychain or secret service; web uses browser crypto.
class SecureAccountCredentialStore implements AccountCredentialStore {
  const SecureAccountCredentialStore();

  static const _key = 'nanotateczki_account_refresh_v1';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}
