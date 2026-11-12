import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/storage/active_storage_namespace.dart';
import '../../core/storage/storage_namespace_manager.dart';
import '../../core/storage/text_storage.dart';
import 'account_session_controller.dart';
import 'api_client.dart';
import 'library_state_merge.dart';

/// Synchronizes account preferences without overwriting unsent local edits.
class AccountSettingsSyncService {
  AccountSettingsSyncService({
    required this.apiClient,
    required this.session,
    this.onRemoteApplied,
    this.useV2 = false,
  });

  final ApiClient apiClient;
  final AccountSessionController session;
  final Future<void> Function()? onRemoteApplied;
  final bool useV2;

  String get _endpoint =>
      useV2 ? '/v2/account-settings' : '/v1/account-settings';

  static const categories = <String>[
    'appPreferences',
    'editorPreferences',
    'recentColors',
    'backupPreferences',
    'libraryState',
  ];
  Future<void>? _running;
  bool _applying = false;
  bool _stopped = false;
  int _generation = 0;
  String? lastError;

  bool _current(String userId, int generation) =>
      !_stopped &&
      _generation == generation &&
      session.isSignedIn &&
      session.userId == userId &&
      (!useV2 ||
          ActiveStorageNamespace.current == StorageNamespace.account(userId));

  bool get isApplying => _applying;

  Future<void> syncNow() {
    final previous = _running;
    if (previous != null) {
      return previous;
    }
    _stopped = false;
    final operation = _syncWithRefresh(++_generation);
    _running = operation;
    return operation.whenComplete(() {
      if (identical(_running, operation)) {
        _running = null;
      }
    });
  }

  Future<void> _syncWithRefresh(int generation) async {
    try {
      await _syncNow(generation);
    } on ApiException catch (error) {
      if (error.statusCode != 401 || !session.isSignedIn) {
        rethrow;
      }
      if (_stopped || _generation != generation) {
        return;
      }
      await session.refresh();
      await _syncNow(generation);
    }
  }

  Future<void> _syncNow(int generation) async {
    final userId = session.userId;
    if (userId == null || !_current(userId, generation)) {
      return;
    }
    final key = useV2
        ? 'account_settings_v2_cursor_${_hash(userId)}.json'
        : _checkpointKey(userId);
    final saved = await readStoredText(key);
    final checkpoint = saved == null
        ? <String, dynamic>{}
        : _object(jsonDecode(saved));
    final entries = checkpoint['settings'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(
            checkpoint['settings'] as Map<String, dynamic>,
          )
        : <String, dynamic>{};
    final response = _object((await apiClient.get(_endpoint)).decodeJson());
    if (!_current(userId, generation)) {
      return;
    }
    final remote = _object(response['settings']);
    var applied = false;
    try {
      for (final category in categories) {
        // Folder and task state belongs to the v2 operation journal.
        if (useV2 && category == 'libraryState') {
          continue;
        }
        if (!_current(userId, generation)) {
          return;
        }
        final fileKey = _fileKey(category, userId);
        final localText = await readStoredText(fileKey);
        if (!_current(userId, generation)) {
          return;
        }
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
        if (category == 'libraryState') {
          applied =
              await _syncLibraryState(
                userId: userId,
                generation: generation,
                key: key,
                fileKey: fileKey,
                entries: entries,
                known: known,
                local: local,
                serverEntry: serverEntry,
              ) ||
              applied;
          continue;
        }
        if (known != null && local != null && !_equivalent(local, knownValue)) {
          if (serverEntry != null && _equivalent(local, remoteValue)) {
            entries[category] = {
              'revision': remoteRevision,
              'value': remoteValue,
            };
            if (!_current(userId, generation)) {
              return;
            }
            await writeStoredText(
              key,
              jsonEncode({'version': 1, 'settings': entries}),
            );
            continue;
          }
          if (remoteRevision != knownRevision &&
              !_equivalent(remoteValue, knownValue)) {
            throw StateError(
              'Account settings conflict in $category'
              '. Local changes have been preserved.',
            );
          }
          final update = _object(
            (await apiClient.putJson('$_endpoint/$category', {
              'expectedRevision': remoteRevision,
              'value': local,
            })).decodeJson(),
          );
          if (!_current(userId, generation)) {
            return;
          }
          entries[category] = {'revision': update['revision'], 'value': local};
        } else if (serverEntry != null) {
          if (!_equivalent(local, remoteValue)) {
            _applying = true;
            try {
              if (known == null && local != null) {
                if (!_current(userId, generation)) {
                  return;
                }
                await _savePreimportCopy(userId, category, local, generation);
              }
              if (!_current(userId, generation)) {
                return;
              }
              // An edit may arrive while preserving the first-sync backup.
              // Never replace newer local preferences with an older download.
              final latestText = await readStoredText(fileKey);
              if (!_current(userId, generation)) {
                return;
              }
              final latestLocal = latestText == null || latestText.isEmpty
                  ? null
                  : jsonDecode(latestText);
              if (!_equivalent(latestLocal, local)) {
                // Bind this remote revision without consuming the new edit.
                // On the next pass it is uploaded with the server CAS token.
                entries[category] = {
                  'revision': remoteRevision,
                  'value': remoteValue,
                };
                await writeStoredText(
                  key,
                  jsonEncode({'version': 1, 'settings': entries}),
                );
                continue;
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
            (await apiClient.putJson('$_endpoint/$category', {
              'expectedRevision': 0,
              'value': local,
            })).decodeJson(),
          );
          if (!_current(userId, generation)) {
            return;
          }
          entries[category] = {'revision': update['revision'], 'value': local};
        }
        if (!_current(userId, generation)) {
          return;
        }
        await writeStoredText(
          key,
          jsonEncode({'version': 1, 'settings': entries}),
        );
      }
      lastError = null;
      if (applied && _current(userId, generation)) {
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

  Future<bool> _syncLibraryState({
    required String userId,
    required int generation,
    required String key,
    required String fileKey,
    required Map<String, dynamic> entries,
    required Map<String, dynamic>? known,
    required Object? local,
    required Map<String, dynamic>? serverEntry,
  }) async {
    if (local == null && serverEntry == null) {
      return false;
    }
    var currentRemote = serverEntry;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!_current(userId, generation)) {
        return false;
      }
      final revision = currentRemote?['revision'] as int? ?? 0;
      final remoteValue = currentRemote?['value'];
      // An account with an existing server revision must be authoritative
      // on the first synchronization of this device. In particular, a
      // historical local folder must not recreate a server-side deletion.
      // Explicit Local -> Account import is handled separately.
      final desired =
          known == null &&
              currentRemote != null &&
              remoteValue is Map<String, dynamic>
          ? Map<String, dynamic>.from(remoteValue)
          : mergeAccountLibraryState(
              base: known?['value'],
              local: local,
              remote: remoteValue,
            );
      final shouldUpload =
          local != null &&
          (currentRemote == null || !_equivalent(desired, remoteValue));
      if (shouldUpload) {
        try {
          currentRemote = _object(
            (await apiClient.putJson('$_endpoint/libraryState', {
              'expectedRevision': revision,
              'value': desired,
            })).decodeJson(),
          );
        } on ApiException catch (error) {
          if (error.statusCode != 409 || attempt == 3) {
            rethrow;
          }
          final fresh = _object(
            (await apiClient.get('/v1/account-settings')).decodeJson(),
          );
          final settings = _object(fresh['settings']);
          currentRemote = settings['libraryState'] is Map<String, dynamic>
              ? settings['libraryState'] as Map<String, dynamic>
              : null;
          continue;
        }
      }
      final resolved = currentRemote == null
          ? desired
          : _object(currentRemote['value']);
      // The user may have edited planner tasks or folders while REST was
      // in flight. Never replace newer local bytes with our older snapshot.
      final latestText = await readStoredText(fileKey);
      final latestLocal = latestText == null || latestText.isEmpty
          ? null
          : jsonDecode(latestText);
      // Compare any in-flight local edit with the *pre-request* snapshot.
      // Otherwise a newly fetched remote folder looks like a local deletion.
      final mergedLocal = _equivalent(latestLocal, local)
          ? resolved
          : mergeAccountLibraryState(
              base: local,
              local: latestLocal,
              remote: resolved,
            );
      var applied = false;
      if (_current(userId, generation) &&
          !_equivalent(latestLocal, mergedLocal)) {
        _applying = true;
        try {
          if (known == null && local != null) {
            await _savePreimportCopy(userId, 'libraryState', local, generation);
          }
          if (!_current(userId, generation)) {
            return false;
          }
          await writeStoredText(fileKey, jsonEncode(mergedLocal));
          applied = true;
        } finally {
          _applying = false;
        }
      }
      if (currentRemote != null) {
        entries['libraryState'] = {
          'revision': currentRemote['revision'],
          'value': resolved,
        };
      }
      if (!_current(userId, generation)) {
        return false;
      }
      await writeStoredText(
        key,
        jsonEncode({'version': 1, 'settings': entries}),
      );
      return applied;
    }
    throw StateError('Account library metadata changed during sync.');
  }

  void stop() {
    _stopped = true;
    _generation++;
    lastError = null;
  }

  /// Wait for the old account's request to finish after invalidating it.
  Future<void> stopAndDrain() async {
    stop();
    try {
      await _running;
    } catch (_) {
      // The generation fence makes a failed old request harmless.
    }
  }

  static bool _equivalent(Object? left, Object? right) =>
      jsonEncode(_canonical(left)) == jsonEncode(_canonical(right));

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.whereType<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) {
      return value.map(_canonical).toList();
    }
    if (value is num) {
      return value.toDouble();
    }
    return value;
  }

  static Map<String, dynamic> _object(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Invalid account settings response.');
    }
    return raw;
  }

  static String _hash(String userId) =>
      sha256.convert(utf8.encode(userId)).toString().substring(0, 16);

  static String _checkpointKey(String userId) =>
      'account_settings_cursor_${_hash(userId)}.json';

  static String _fileKey(String category, String userId) {
    return switch (category) {
      'appPreferences' => 'app_prefs.json',
      'editorPreferences' => 'editor_prefs.json',
      'recentColors' => 'shared_recent_colors.json',
      'libraryState' => 'library_folders.json',
      'backupPreferences' => 'server_backup_preferences_${_hash(userId)}.json',
      _ => throw ArgumentError.value(category),
    };
  }

  Future<void> _savePreimportCopy(
    String userId,
    String category,
    Object value,
    int generation,
  ) async {
    if (!_current(userId, generation)) {
      return;
    }
    final key = 'account_preimport_${_hash(userId)}.json';
    final old = await readStoredText(key);
    if (!_current(userId, generation)) {
      return;
    }
    final previous = old == null
        ? <String, dynamic>{}
        : _object(jsonDecode(old));
    if (previous.containsKey(category)) {
      return;
    }
    previous[category] = value;
    if (!_current(userId, generation)) {
      return;
    }
    await writeStoredText(key, jsonEncode(previous));
  }
}
