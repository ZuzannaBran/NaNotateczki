import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/text_storage.dart';
import 'api_client.dart';

enum AccountDataMode { localOnly, account }

class AccountSessionController extends ChangeNotifier {
  AccountSessionController(this.apiClient);

  static const profileStorageKey = 'account_profile.json';

  final ApiClient apiClient;
  AccountDataMode mode = AccountDataMode.localOnly;
  AccountDataMode preferredMode = AccountDataMode.localOnly;
  String? userId;
  String? username;
  String? localDisplayName;
  String? lastAccountUsername;
  String? _refreshToken;
  DateTime? accessExpiresAt;
  bool profileLoaded = false;
  bool onboardingComplete = false;
  bool accountDialogOpen = false;
  bool isBusy = false;
  String? error;
  Future<void>? _profileLoad;
  bool _disposed = false;

  static final usernamePattern = RegExp(r'^[a-zA-Z0-9_]{3,32}  bool get isSignedIn => mode == AccountDataMode.account && userId != null;
  bool get shouldShowStartupDialog =>
      profileLoaded &&
      !accountDialogOpen &&
      (!onboardingComplete ||
          (preferredMode == AccountDataMode.account && !isSignedIn));
  bool get isLocalProfile => !isSignedIn && localDisplayName != null;
  String get displayName =>
      isSignedIn ? (username ?? 'Account') : (localDisplayName ?? 'Local user');
  String get avatarLetter {
    final trimmed = displayName.trim();
    return trimmed.isEmpty
        ? '?'
        : String.fromCharCode(trimmed.runes.first).toUpperCase();
  }

  void beginAccountInteraction() {
    accountDialogOpen = true;
    _notifyIfActive();
  }

  void endAccountInteraction() {
    accountDialogOpen = false;
    _notifyIfActive();
  }

  void clearError() {
    if (error == null) {
      return;
    }
    error = null;
    _notifyIfActive();
  }

  Future<void> loadProfile() {
    return _profileLoad ??= _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final content = await readStoredText(profileStorageKey);
      if (content != null) {
        final raw = jsonDecode(content);
        if (raw is! Map<String, dynamic> || raw['version'] != 1) {
          throw const FormatException('Unsupported account profile.');
        }
        onboardingComplete = raw['onboardingComplete'] == true;
        preferredMode = raw['preferredMode'] == AccountDataMode.account.name
            ? AccountDataMode.account
            : AccountDataMode.localOnly;
        localDisplayName = _optionalNonEmptyString(raw['localDisplayName']);
        lastAccountUsername = _optionalNonEmptyString(
          raw['lastAccountUsername'],
        );
        // An older profile only stored an email. The server migration
        // normally chooses its local part as the legacy username.
        lastAccountUsername ??= _optionalNonEmptyString(
          raw['lastAccountEmail'],
        )?.split('@').first.toLowerCase();
      }
    } catch (failure) {
      if (!_disposed) {
        error = _failureMessage(failure);
      }
    } finally {
      if (!_disposed) {
        profileLoaded = true;
        _notifyIfActive();
      }
    }
  }

  Future<void> register(String username, String password) async {
    await _authenticate('/v1/auth/register', username, password);
  }

  Future<void> login(String username, String password) async {
    await _authenticate('/v1/auth/login', username, password);
  }

  Future<void> _authenticate(
    String path,
    String rawUsername,
    String password,
  ) async {
    if (!apiClient.isConfigured) {
      throw StateError('BACKEND_URL is not configured.');
    }
    final normalizedUsername = rawUsername.trim().toLowerCase();
    if (!usernamePattern.hasMatch(normalizedUsername) ||
        password.isEmpty ||
        password.length > 256) {
      throw const FormatException(
        'Use a username of 3 to 32 letters, numbers or underscores.',
      );
    }
    if (path == '/v1/auth/register' &&
        (password.length < 8 || password.length > 128)) {
      throw const FormatException(
        'The password must contain 8 to 128 characters.',
      );
    }
    isBusy = true;
    error = null;
    _notifyIfActive();
    try {
      final response = await apiClient.postJson(path, {
        'username': normalizedUsername,
        'password': password,
      }, authenticated: false);
      _applySession(response.decodeJson());
      preferredMode = AccountDataMode.account;
      onboardingComplete = true;
      lastAccountUsername = normalizedUsername;
      if (profileLoaded) {
        try {
          await _saveProfile();
        } catch (failure) {
          error = _failureMessage(failure);
        }
      }
    } catch (failure) {
      error = _failureMessage(failure);
      rethrow;
    } finally {
      isBusy = false;
      _notifyIfActive();
    }
  }

  Future<void> refresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) {
      throw StateError('No refresh session is available.');
    }
    final response = await apiClient.postJson('/v1/auth/refresh', {
      'refreshToken': refreshToken,
    }, authenticated: false);
    _applySession(response.decodeJson());
    _notifyIfActive();
  }

  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    if (!isSignedIn) {
      throw StateError('Sign in before changing the password.');
    }
    if (currentPassword.isEmpty || currentPassword.length > 256) {
      throw const FormatException('Enter the current password.');
    }
    if (newPassword.length < 8 || newPassword.length > 128) {
      throw const FormatException(
        'The new password must contain 8 to 128 characters.',
      );
    }
    isBusy = true;
    error = null;
    _notifyIfActive();
    try {
      await apiClient.postJson('/v1/auth/change-password', {
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      });
    } catch (failure) {
      error = _failureMessage(failure);
      rethrow;
    } finally {
      isBusy = false;
      _notifyIfActive();
    }
  }

  Future<void> logout() async {
    final refreshToken = _refreshToken;
    try {
      if (refreshToken != null && apiClient.accessToken != null) {
        await apiClient.postJson('/v1/auth/logout', {
          'refreshToken': refreshToken,
        });
      }
    } finally {
      useLocalOnly();
    }
  }

  void useLocalOnly() {
    _clearSession();
    error = null;
    _notifyIfActive();
  }

  Future<void> useLocalProfile(String rawDisplayName) async {
    final displayName = rawDisplayName.trim();
    if (displayName.isEmpty || displayName.length > 80) {
      throw const FormatException(
        'The local name must contain 1 to 80 characters.',
      );
    }
    _clearSession();
    localDisplayName = displayName;
    preferredMode = AccountDataMode.localOnly;
    onboardingComplete = true;
    profileLoaded = true;
    error = null;
    try {
      await _saveProfile();
    } catch (failure) {
      error = _failureMessage(failure);
      _notifyIfActive();
      rethrow;
    }
    _notifyIfActive();
  }

  void requireAccountReauthentication() {
    _clearSession();
    preferredMode = AccountDataMode.account;
    onboardingComplete = true;
    error = null;
    _notifyIfActive();
  }

  void _clearSession() {
    mode = AccountDataMode.localOnly;
    userId = null;
    username = null;
    _refreshToken = null;
    accessExpiresAt = null;
    apiClient.setAccessToken(null);
  }

  void _applySession(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Malformed authentication response.');
    }
    final accessToken = raw['accessToken'];
    final refreshToken = raw['refreshToken'];
    final responseUserId = raw['userId'];
    final responseUsername = raw['username'];
    final expiresIn = raw['expiresIn'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        refreshToken is! String ||
        refreshToken.isEmpty ||
        responseUserId is! String ||
        responseUsername is! String ||
        expiresIn is! num) {
      throw const FormatException('Incomplete authentication response.');
    }
    apiClient.setAccessToken(accessToken);
    _refreshToken = refreshToken;
    userId = responseUserId;
    username = responseUsername;
    accessExpiresAt = DateTime.now().toUtc().add(
      Duration(seconds: expiresIn.toInt()),
    );
    mode = AccountDataMode.account;
  }

  Future<void> _saveProfile() {
    return writeStoredText(
      profileStorageKey,
      jsonEncode({
        'version': 1,
        'onboardingComplete': onboardingComplete,
        'preferredMode': preferredMode.name,
        'localDisplayName': localDisplayName,
        'lastAccountUsername': lastAccountUsername,
      }),
    );
  }

  static String? _optionalNonEmptyString(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return null;
    }
    return raw.trim();
  }

  static String _failureMessage(Object failure) {
    if (failure is ApiException) {
      return failure.message;
    }
    if (failure is FormatException) {
      return failure.message;
    }
    return failure.toString();
  }

  void _notifyIfActive() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @visibleForTesting
  String? get debugRefreshToken => _refreshToken;

  @visibleForTesting
  String debugSessionJson() => jsonEncode({
    'mode': mode.name,
    'userId': userId,
    'username': username,
    'preferredMode': preferredMode.name,
    'localDisplayName': localDisplayName,
    'accessExpiresAt': accessExpiresAt?.toIso8601String(),
  });
}
);

  bool get isSignedIn => mode == AccountDataMode.account && userId != null;
  bool get shouldShowStartupDialog =>
      profileLoaded &&
      !accountDialogOpen &&
      (!onboardingComplete ||
          (preferredMode == AccountDataMode.account && !isSignedIn));
  bool get isLocalProfile => !isSignedIn && localDisplayName != null;
  String get displayName =>
      isSignedIn ? (username ?? 'Account') : (localDisplayName ?? 'Local user');
  String get avatarLetter {
    final trimmed = displayName.trim();
    return trimmed.isEmpty
        ? '?'
        : String.fromCharCode(trimmed.runes.first).toUpperCase();
  }

  void beginAccountInteraction() {
    accountDialogOpen = true;
    _notifyIfActive();
  }

  void endAccountInteraction() {
    accountDialogOpen = false;
    _notifyIfActive();
  }

  void clearError() {
    if (error == null) {
      return;
    }
    error = null;
    _notifyIfActive();
  }

  Future<void> loadProfile() {
    return _profileLoad ??= _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final content = await readStoredText(profileStorageKey);
      if (content != null) {
        final raw = jsonDecode(content);
        if (raw is! Map<String, dynamic> || raw['version'] != 1) {
          throw const FormatException('Unsupported account profile.');
        }
        onboardingComplete = raw['onboardingComplete'] == true;
        preferredMode = raw['preferredMode'] == AccountDataMode.account.name
            ? AccountDataMode.account
            : AccountDataMode.localOnly;
        localDisplayName = _optionalNonEmptyString(raw['localDisplayName']);
        lastAccountUsername = _optionalNonEmptyString(
          raw['lastAccountUsername'],
        );
        // An older profile only stored an email. The server migration
        // normally chooses its local part as the legacy username.
        lastAccountUsername ??= _optionalNonEmptyString(
          raw['lastAccountEmail'],
        )?.split('@').first.toLowerCase();
      }
    } catch (failure) {
      if (!_disposed) {
        error = _failureMessage(failure);
      }
    } finally {
      if (!_disposed) {
        profileLoaded = true;
        _notifyIfActive();
      }
    }
  }

  Future<void> register(String username, String password) async {
    await _authenticate('/v1/auth/register', username, password);
  }

  Future<void> login(String username, String password) async {
    await _authenticate('/v1/auth/login', username, password);
  }

  Future<void> _authenticate(
    String path,
    String rawUsername,
    String password,
  ) async {
    if (!apiClient.isConfigured) {
      throw StateError('BACKEND_URL is not configured.');
    }
    final normalizedUsername = rawUsername.trim().toLowerCase();
    if (!usernamePattern.hasMatch(normalizedUsername) ||
        password.isEmpty ||
        password.length > 256) {
      throw const FormatException(
        'Use a username of 3 to 32 letters, numbers or underscores.',
      );
    }
    if (path == '/v1/auth/register' &&
        (password.length < 8 || password.length > 128)) {
      throw const FormatException(
        'The password must contain 8 to 128 characters.',
      );
    }
    isBusy = true;
    error = null;
    _notifyIfActive();
    try {
      final response = await apiClient.postJson(path, {
        'username': normalizedUsername,
        'password': password,
      }, authenticated: false);
      _applySession(response.decodeJson());
      preferredMode = AccountDataMode.account;
      onboardingComplete = true;
      lastAccountUsername = normalizedUsername;
      if (profileLoaded) {
        try {
          await _saveProfile();
        } catch (failure) {
          error = _failureMessage(failure);
        }
      }
    } catch (failure) {
      error = _failureMessage(failure);
      rethrow;
    } finally {
      isBusy = false;
      _notifyIfActive();
    }
  }

  Future<void> refresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) {
      throw StateError('No refresh session is available.');
    }
    final response = await apiClient.postJson('/v1/auth/refresh', {
      'refreshToken': refreshToken,
    }, authenticated: false);
    _applySession(response.decodeJson());
    _notifyIfActive();
  }

  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    if (!isSignedIn) {
      throw StateError('Sign in before changing the password.');
    }
    if (currentPassword.isEmpty || currentPassword.length > 256) {
      throw const FormatException('Enter the current password.');
    }
    if (newPassword.length < 8 || newPassword.length > 128) {
      throw const FormatException(
        'The new password must contain 8 to 128 characters.',
      );
    }
    isBusy = true;
    error = null;
    _notifyIfActive();
    try {
      await apiClient.postJson('/v1/auth/change-password', {
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      });
    } catch (failure) {
      error = _failureMessage(failure);
      rethrow;
    } finally {
      isBusy = false;
      _notifyIfActive();
    }
  }

  Future<void> logout() async {
    final refreshToken = _refreshToken;
    try {
      if (refreshToken != null && apiClient.accessToken != null) {
        await apiClient.postJson('/v1/auth/logout', {
          'refreshToken': refreshToken,
        });
      }
    } finally {
      useLocalOnly();
    }
  }

  void useLocalOnly() {
    _clearSession();
    error = null;
    _notifyIfActive();
  }

  Future<void> useLocalProfile(String rawDisplayName) async {
    final displayName = rawDisplayName.trim();
    if (displayName.isEmpty || displayName.length > 80) {
      throw const FormatException(
        'The local name must contain 1 to 80 characters.',
      );
    }
    _clearSession();
    localDisplayName = displayName;
    preferredMode = AccountDataMode.localOnly;
    onboardingComplete = true;
    profileLoaded = true;
    error = null;
    try {
      await _saveProfile();
    } catch (failure) {
      error = _failureMessage(failure);
      _notifyIfActive();
      rethrow;
    }
    _notifyIfActive();
  }

  void requireAccountReauthentication() {
    _clearSession();
    preferredMode = AccountDataMode.account;
    onboardingComplete = true;
    error = null;
    _notifyIfActive();
  }

  void _clearSession() {
    mode = AccountDataMode.localOnly;
    userId = null;
    username = null;
    _refreshToken = null;
    accessExpiresAt = null;
    apiClient.setAccessToken(null);
  }

  void _applySession(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Malformed authentication response.');
    }
    final accessToken = raw['accessToken'];
    final refreshToken = raw['refreshToken'];
    final responseUserId = raw['userId'];
    final responseUsername = raw['username'];
    final expiresIn = raw['expiresIn'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        refreshToken is! String ||
        refreshToken.isEmpty ||
        responseUserId is! String ||
        responseUsername is! String ||
        expiresIn is! num) {
      throw const FormatException('Incomplete authentication response.');
    }
    apiClient.setAccessToken(accessToken);
    _refreshToken = refreshToken;
    userId = responseUserId;
    username = responseUsername;
    accessExpiresAt = DateTime.now().toUtc().add(
      Duration(seconds: expiresIn.toInt()),
    );
    mode = AccountDataMode.account;
  }

  Future<void> _saveProfile() {
    return writeStoredText(
      profileStorageKey,
      jsonEncode({
        'version': 1,
        'onboardingComplete': onboardingComplete,
        'preferredMode': preferredMode.name,
        'localDisplayName': localDisplayName,
        'lastAccountUsername': lastAccountUsername,
      }),
    );
  }

  static String? _optionalNonEmptyString(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return null;
    }
    return raw.trim();
  }

  static String _failureMessage(Object failure) {
    if (failure is ApiException) {
      return failure.message;
    }
    if (failure is FormatException) {
      return failure.message;
    }
    return failure.toString();
  }

  void _notifyIfActive() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @visibleForTesting
  String? get debugRefreshToken => _refreshToken;

  @visibleForTesting
  String debugSessionJson() => jsonEncode({
    'mode': mode.name,
    'userId': userId,
    'username': username,
    'preferredMode': preferredMode.name,
    'localDisplayName': localDisplayName,
    'accessExpiresAt': accessExpiresAt?.toIso8601String(),
  });
}
