import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/storage/text_storage.dart';
import 'account_session_controller.dart';
import 'api_client.dart';

/// Synchronizes account preferences without overwriting unsent local edits.
class AccountSettingsSyncService {
  AccountSettingsSyncService({
    required this.apiClient,
    required this.session,
    this.onRemoteApplied,
  });

  final ApiClient apiClient;
  final AccountSessionController session;
  final Future<void> Function()? onRemoteApplied;

  static const categories = <String>[
    'appPreferences',
    'editorPreferences',
    'recentColors',
    'backupPreferences',
  ];
  Future<void>? _running;
  bool _applying = false;
  String? lastError;

  bool get isApplying => _applying;

  Future<void> syncNow() {
    final previous = _running;
    if (previous != null) {
      return previous;
    }
    final operation = _syncNow();
    _running = operation;
    return operation.whenComplete(() {
      if (identical(_running, operation)) {
        _running = null;
      }
    });
  }

  Future<void> _syncNow() async {
    final userId = session.userId;
    if (!session.isSignedIn || userId == null) {
      return;
    }
    final key = _checkpointKey(userId);
    final saved = await readStoredText(key);
    final checkpoint = saved == null
        ? <String, dynamic>{}
        : _object(jsonDecode(saved));
    final entries = checkpoint['settings'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(
            checkpoint['settings'] as Map<String, dynamic>,
          )
        : <String, dynamic>{};
    final response = _object(
      (await apiClient.get('/v1/account-settings')).decodeJson(),
    );
    final remote = _object(response['settings']);
    var applied = false;
    try {
      for (final category in categories) {
        if (session.userId != userId || !session.isSignedIn) {
          return;
        }
        final fileKey = _fileKey(category, userId);
        final localText = await readStoredText(fileKey);
        final local = localText == null || localText.isEmpty
            ? null
            : jsonDecode(localText);
        final known = entries[category] is Map<String, dynamic>
            ? entries[category] as Map<String, dynamic>
            : null;
        final serverEntry = remote[category] is Map<String, dynamic>
            ? remote[category] as Map<String, dynamic>
            : null;
        final remoteRevision = serverEntry?['revision'] is int
            ? serverEntry!['revision'] as int
            : 0;
        final remoteValue = serverEntry?['value'];
        final knownRevision = known?['revision'] is int
            ? known!['revision'] as int
            : 0;
        final knownValue = known?['value'];
        if (known != null && local != null &&
            !_equivalent(local, knownValue)) {
          if (remoteRevision != knownRevision &&
              !_equivalent(remoteValue, knownValue)) {
            throw StateError(
              'Account settings conflict in ' + category +
              '. Local changes have been preserved.',
            );
          }
          final update = _object(
            (await apiClient.putJson(
              '/v1/account-settings/' + category,
              {'expectedRevision': remoteRevision, 'value': local},
            )).decodeJson(),
          );
          entries[category] = {
            'revision': update['revision'],
            'value': local,
          };
        } else if (serverEntry != null) {
          if (!_equivalent(local, remoteValue)) {
            _applying = true;
            try {
              if (known == null && local != null) {
                await _savePreimportCopy(userId, category, local);
              }
              await writeStoredText(fileKey, jsonEncode(remoteValue));
              applied = true;
            } finally {
              _applying = false;
            }
          }
          entries[category] = {
            'revision': remoteRevision,
            'value': remoteValue,
          };
        } else if (local != null) {
          final update = _object(
            (await apiClient.putJson(
              '/v1/account-settings/' + category,
              {'expectedRevision': 0, 'value': local},
            )).decodeJson(),
          );
          entries[category] = {
            'revision': update['revision'],
            'value': local,
          };
        }
        await writeStoredText(
          key,
          jsonEncode({'version': 1, 'settings': entries}),
        );
      }
      lastError = null;
      if (applied && session.userId == userId) {
        _applying = true;
        try {
          await onRemoteApplied?.call();
        } finally {
          _applying = false;
        }
      }
    } catch (error) {
      lastError = error.toString();
      rethrow;
    }
  }

  void stop() {
    lastError = null;
  }

  static bool _equivalent(Object? left, Object? right) =>
      jsonEncode(left) == jsonEncode(right);

  static Map<String, dynamic> _object(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Invalid account settings response.');
    }
    return raw;
  }

  static String _hash(String userId) =>
      sha256.convert(utf8.encode(userId)).toString().substring(0, 16);

  static String _checkpointKey(String userId) =>
      'account_settings_cursor_' + _hash(userId) + '.json';

  static String _fileKey(String category, String userId) {
    return switch (category) {
      'appPreferences' => 'app_prefs.json',
      'editorPreferences' => 'editor_prefs.json',
      'recentColors' => 'shared_recent_colors.json',
      'backupPreferences' =>
        'server_backup_preferences_' + _hash(userId) + '.json',
      _ => throw ArgumentError.value(category),
    };
  }

  static Future<void> _savePreimportCopy(
    String userId,
    String category,
    Object value,
  ) async {
    final key = 'account_preimport_' + _hash(userId) + '.json';
    final old = await readStoredText(key);
    final previous = old == null
        ? <String, dynamic>{}
        : _object(jsonDecode(old));
    if (previous.containsKey(category)) {
      return;
    }
    previous[category] = value;
    await writeStoredText(key, jsonEncode(previous));
  }
}
