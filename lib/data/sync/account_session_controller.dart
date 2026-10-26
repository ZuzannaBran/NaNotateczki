import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api_client.dart';

enum AccountDataMode { localOnly, account }

class AccountSessionController extends ChangeNotifier {
  AccountSessionController(this.apiClient);

  final ApiClient apiClient;
  AccountDataMode mode = AccountDataMode.localOnly;
  String? userId;
  String? email;
  String? _refreshToken;
  DateTime? accessExpiresAt;
  bool isBusy = false;
  String? error;

  bool get isSignedIn => mode == AccountDataMode.account && userId != null;

  Future<void> register(String email, String password) async {
    await _authenticate('/v1/auth/register', email, password);
  }

  Future<void> login(String email, String password) async {
    await _authenticate('/v1/auth/login', email, password);
  }

  Future<void> _authenticate(
    String path,
    String rawEmail,
    String password,
  ) async {
    if (!apiClient.isConfigured) {
      throw StateError('BACKEND_URL is not configured.');
    }
    final normalizedEmail = rawEmail.trim().toLowerCase();
    if (normalizedEmail.isEmpty || password.length < 12) {
      throw const FormatException(
        'A valid e-mail and a password of at least 12 characters are required.',
      );
    }
    isBusy = true;
    error = null;
    notifyListeners();
    try {
      final response = await apiClient.postJson(path, {
        'email': normalizedEmail,
        'password': password,
      }, authenticated: false);
      _applySession(response.decodeJson());
    } catch (failure) {
      error = failure.toString();
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
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
    notifyListeners();
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
    mode = AccountDataMode.localOnly;
    userId = null;
    email = null;
    _refreshToken = null;
    accessExpiresAt = null;
    apiClient.setAccessToken(null);
    error = null;
    notifyListeners();
  }

  void _applySession(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Malformed authentication response.');
    }
    final accessToken = raw['accessToken'];
    final refreshToken = raw['refreshToken'];
    final responseUserId = raw['userId'];
    final responseEmail = raw['email'];
    final expiresIn = raw['expiresIn'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        refreshToken is! String ||
        refreshToken.isEmpty ||
        responseUserId is! String ||
        responseEmail is! String ||
        expiresIn is! num) {
      throw const FormatException('Incomplete authentication response.');
    }
    apiClient.setAccessToken(accessToken);
    _refreshToken = refreshToken;
    userId = responseUserId;
    email = responseEmail;
    accessExpiresAt = DateTime.now().toUtc().add(
      Duration(seconds: expiresIn.toInt()),
    );
    mode = AccountDataMode.account;
  }

  @visibleForTesting
  String? get debugRefreshToken => _refreshToken;

  @visibleForTesting
  String debugSessionJson() => jsonEncode({
    'mode': mode.name,
    'userId': userId,
    'email': email,
    'accessExpiresAt': accessExpiresAt?.toIso8601String(),
  });
}
