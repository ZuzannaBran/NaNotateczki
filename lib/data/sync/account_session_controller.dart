import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/text_storage.dart';
import 'account_credential_store.dart';
import 'api_client.dart';

enum AccountDataMode { localOnly, account }

class AccountSessionController extends ChangeNotifier {
  AccountSessionController(
    this.apiClient, {
    AccountCredentialStore? credentialStore,
    this.onBeforeAccountRestore,
    this.onBeforeAccountChange,
  }) : _credentialStore =
           credentialStore ?? const SecureAccountCredentialStore();

  static const profileStorageKey = 'account_profile.json';

  final ApiClient apiClient;
  final VoidCallback? onBeforeAccountRestore;
  final Future<void> Function()? onBeforeAccountChange;
  final AccountCredentialStore _credentialStore;
  Future<void> _credentialQueue = Future<void>.value();
  int _sessionGeneration = 0;
  AccountDataMode mode = AccountDataMode.localOnly;
  AccountDataMode preferredMode = AccountDataMode.localOnly;
  String? userId;
  String? username;
  String? localDisplayName;
  String? lastAccountUsername;
  String? _boundUserId;
  String? _refreshToken;
  DateTime? accessExpiresAt;
  bool profileLoaded = false;
  bool onboardingComplete = false;
  bool accountDialogOpen = false;
  bool isBusy = false;
  String? error;
  Future<void>? _profileLoad;
  Future<void>? _refreshInProgress;
  Future<void>? _restoreInProgress;
  bool _disposed = false;

  static final usernamePattern = RegExp(
    r'^[a-zA-Z0-9_]{3,32}' + String.fromCharCode(36),
  );
  bool get isSignedIn => mode == AccountDataMode.account && userId != null;
  bool get shouldShowStartupDialog =>
      profileLoaded && !accountDialogOpen && !onboardingComplete;
  bool get isLocalProfile => !isSignedIn && localDisplayName != null;
  String get displayName => isSignedIn
      ? (username ?? 'Account')
      : preferredMode == AccountDataMode.account
      ? (lastAccountUsername ?? 'Account')
      : (localDisplayName ?? 'Local user');
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
        _boundUserId = _optionalNonEmptyString(raw['boundUserId']);
      }
      if (preferredMode == AccountDataMode.account &&
          onboardingComplete &&
          _boundUserId != null) {
        onBeforeAccountRestore?.call();
        await retryPersistedSession();
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
    _sessionGeneration++;
    isBusy = true;
    error = null;
    _notifyIfActive();
    try {
      // The old account must stop all writers before the API identity changes.
      await onBeforeAccountChange?.call();
      final response = await apiClient.postJson(path, {
        'username': normalizedUsername,
        'password': password,
      }, authenticated: false);
      final incoming = response.decodeJson();
      if (incoming is! Map<String, dynamic> ||
          incoming['userId'] is! String ||
          incoming['username'] != normalizedUsername) {
        throw const FormatException('Malformed account identity response.');
      }
      final incomingUserId = incoming['userId'] as String;
      _applySession(incoming);
      // Account namespaces are isolated; an explicit new login selects its own.
      _boundUserId = incomingUserId;
      preferredMode = AccountDataMode.account;
      onboardingComplete = true;
      lastAccountUsername = normalizedUsername;
      if (profileLoaded) {
        try {
          await _saveProfile();
        } catch (failure) {
          throw StateError(
            'Account identity could not be saved. Backup is disabled: '
            '${_failureMessage(failure)}',
          );
        }
      }
      await _persistRefreshCredential();
    } catch (failure) {
      _clearSession();
      error = _failureMessage(failure);
      rethrow;
    } finally {
      isBusy = false;
      _notifyIfActive();
    }
  }

  Future<void> refresh() {
    final running = _refreshInProgress;
    if (running != null) {
      return running;
    }
    final future = _refreshSession();
    _refreshInProgress = future;
    return future.whenComplete(() {
      if (identical(_refreshInProgress, future)) {
        _refreshInProgress = null;
      }
    });
  }

  Future<void> _refreshSession() async {
    final refreshToken = _refreshToken;
    final expectedUserId = userId;
    final expectedUsername = username;
    if (refreshToken == null ||
        expectedUserId == null ||
        expectedUsername == null) {
      throw StateError('No refresh session is available.');
    }
    final response = await apiClient.postJson('/v1/auth/refresh', {
      'refreshToken': refreshToken,
    }, authenticated: false);
    if (_disposed || refreshToken != _refreshToken || !isSignedIn) {
      return;
    }
    final incoming = response.decodeJson();
    if (!_matchesIdentity(incoming, expectedUserId, expectedUsername)) {
      throw const FormatException('Refresh returned another account.');
    }
    _applySession(incoming);
    await _persistRefreshCredential();
    _notifyIfActive();
  }

  /// Retries a remembered login after an offline startup, without prompting.
  /// The single-flight guard protects rotating tokens from concurrent retries.
  Future<void> retryPersistedSession() {
    if (_disposed ||
        isSignedIn ||
        isBusy ||
        preferredMode != AccountDataMode.account ||
        !onboardingComplete ||
        _boundUserId == null) {
      return Future<void>.value();
    }
    final running = _restoreInProgress;
    if (running != null) {
      return running;
    }
    final operation = _restorePersistedSession();
    _restoreInProgress = operation;
    return operation.whenComplete(() {
      if (identical(_restoreInProgress, operation)) {
        _restoreInProgress = null;
      }
      _notifyIfActive();
    });
  }

  Future<void> _restorePersistedSession() async {
    final generation = _sessionGeneration;
    try {
      final saved = await _credentialStore.read();
      if (saved == null || _disposed || generation != _sessionGeneration) {
        return;
      }
      final data = jsonDecode(saved);
      if (data is! Map<String, dynamic> ||
          data['version'] != 1 ||
          data['backend'] != apiClient.baseUri.toString() ||
          data['userId'] != _boundUserId ||
          data['username'] != lastAccountUsername ||
          data['refreshToken'] is! String ||
          (data['refreshToken'] as String).isEmpty) {
        await _discardRestoredCredential(generation);
        return;
      }
      final response = await apiClient.postJson('/v1/auth/refresh', {
        'refreshToken': data['refreshToken'],
      }, authenticated: false);
      if (_disposed || generation != _sessionGeneration) {
        return;
      }
      final incoming = response.decodeJson();
      if (!_matchesIdentity(
        incoming,
        data['userId'] as String,
        data['username'] as String,
      )) {
        await _discardRestoredCredential(generation);
        return;
      }
      _applySession(incoming);
      await _persistRefreshCredential();
    } on ApiException catch (failure) {
      if (failure.statusCode == 400 ||
          failure.statusCode == 401 ||
          failure.statusCode == 403 ||
          failure.statusCode == 409 ||
          failure.statusCode == 422) {
        await _discardRestoredCredential(generation);
      }
    } on FormatException {
      await _discardRestoredCredential(generation);
    } catch (_) {
      // Offline and unavailable keyrings do not block local notebooks.
    }
  }

  Future<void> _discardRestoredCredential(int generation) async {
    if (!_disposed && generation == _sessionGeneration) {
      await _queueCredential(null);
    }
  }

  bool _matchesIdentity(
    Object? response,
    String expectedUserId,
    String expectedUsername,
  ) {
    return response is Map<String, dynamic> &&
        response['userId'] == expectedUserId &&
        response['username'] == expectedUsername;
  }

  Future<void> _persistRefreshCredential() async {
    final token = _refreshToken;
    if (token == null || userId == null || username == null) {
      return;
    }
    try {
      await _queueCredential(
        jsonEncode({
          'version': 1,
          'backend': apiClient.baseUri.toString(),
          'userId': userId,
          'username': username,
          'refreshToken': token,
        }),
      );
    } catch (_) {
      error = 'Automatic sign-in is unavailable on this device.';
    }
  }

  Future<void> _queueCredential(String? value) {
    final pending = _credentialQueue.then((_) {
      return value == null
          ? _credentialStore.delete()
          : _credentialStore.write(value);
    });
    _credentialQueue = pending.catchError((Object _) {});
    return pending;
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
    // Drain writers while the identity and token are still valid.
    // A failed flush must not revoke an account with unsaved local edits.
    await onBeforeAccountChange?.call();
    final refreshToken = _refreshToken;
    Object? remoteFailure;
    StackTrace? remoteStack;
    try {
      if (refreshToken != null && apiClient.accessToken != null) {
        await apiClient
            .postJson('/v1/auth/logout', {'refreshToken': refreshToken})
            .timeout(const Duration(seconds: 5));
      }
    } catch (failure, stackTrace) {
      // Local sign-out must still work without an available server.
      remoteFailure = failure;
      remoteStack = stackTrace;
    }

    // Do not change the visible session until secure credential deletion has
    // succeeded. An old refresh token must not silently survive account switch.
    await _queueCredential(null);
    final previousMode = preferredMode;
    final previousOnboarding = onboardingComplete;
    preferredMode = AccountDataMode.localOnly;
    onboardingComplete = false;
    try {
      await _saveProfile();
    } catch (_) {
      preferredMode = previousMode;
      onboardingComplete = previousOnboarding;
      rethrow;
    }
    _clearSession();
    error = null;
    _notifyIfActive();
    if (remoteFailure != null) {
      Error.throwWithStackTrace(remoteFailure, remoteStack!);
    }
  }

  void useLocalOnly() {
    _clearSession();
    unawaited(_queueCredential(null).catchError((Object _) {}));
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
    try {
      await _queueCredential(null);
    } catch (_) {
      // Local mode remains available when the keyring is inaccessible.
    }
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

  Future<void> requireAccountReauthentication() async {
    _clearSession();
    try {
      await _queueCredential(null);
    } catch (_) {
      // Revoked server tokens cannot be used again.
    }
    preferredMode = AccountDataMode.account;
    onboardingComplete = true;
    error = null;
    _notifyIfActive();
  }

  void _clearSession() {
    _sessionGeneration++;
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
        'boundUserId': _boundUserId,
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
