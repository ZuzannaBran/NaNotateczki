import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/storage/app_save_coordinator.dart';
import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';
import '../../features/notebook/domain/notebook_kind.dart';
import '../sync/account_session_controller.dart';
import '../sync/api_client.dart';
import '../sync/notebook_conflicts.dart';
import 'backup_payload_bytes.dart';

class RemoteBackupReceipt {
  const RemoteBackupReceipt({
    required this.backupId,
    required this.checksum,
    required this.verifiedAt,
  });

  final String backupId;
  final String checksum;
  final DateTime verifiedAt;
}

class RemoteBackupService {
  RemoteBackupService({
    required this.repository,
    required this.apiClient,
    required this.session,
  });

  static const int formatVersion = 2;
  static const int maximumSnapshotBytes = 64 * 1024 * 1024;

  final NotebookRepository repository;
  final ApiClient apiClient;
  final AccountSessionController session;

  Future<RemoteBackupReceipt> uploadVerifiedSnapshot({
    required String deviceId,
  }) async {
    if (!session.isSignedIn) {
      throw StateError('Remote backup requires a signed-in account.');
    }
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(deviceId)) {
      throw const FormatException('deviceId must be a UUID.');
    }
    final expiresAt = session.accessExpiresAt;
    if (expiresAt != null &&
        DateTime.now().toUtc().isAfter(
          expiresAt.subtract(const Duration(minutes: 1)),
        )) {
      await session.refresh();
    }
    await AppSaveCoordinator.instance.flushPending();
    await repository.waitForPendingSaves();
    final notebooks = await repository.fetchNotebooks();
    if (repository.lastFetchSkippedCorruptRows) {
      throw StateError('Remote backup refused unreadable notebook data.');
    }

    final libraryState = await readStoredText('library_folders.json');
    final studyPlannerState = await readStoredText('study_planner.json');
    final preferences = await readStoredText('app_prefs.json');
    final editorPreferences = await readStoredText('editor_prefs.json');
    final recentColors = await readStoredText('shared_recent_colors.json');
    final userId = session.userId!;
    final backupPreferences = await readStoredText(
      _backupPreferenceKey(userId),
    );
    final payload = <String, dynamic>{
      'notebooks': repository.encodeSelfContainedBackup(notebooks),
      'libraryState': _decodeOptionalObject(libraryState),
      'studyPlannerState': _decodeOptionalObject(studyPlannerState),
      'appPreferences': _decodeOptionalObject(preferences),
      'editorPreferences': _decodeOptionalObject(editorPreferences),
      'recentColors': recentColors == null
          ? <dynamic>[]
          : _decodeRecentColors(recentColors),
      'backupPreferences': _decodeOptionalObject(backupPreferences),
    };
    // Native platforms serialize and hash off the UI isolate. On Web the
    // caller schedules this operation only after user inactivity.
    final encoded = await compute(_encodeSnapshot, <String, dynamic>{
      'payload': payload,
      'deviceId': deviceId,
    });
    final checksum = encoded.checksum;
    final bytes = encoded.bytes;
    if (bytes.length > maximumSnapshotBytes) {
      throw StateError('Remote backup exceeds the client safety limit.');
    }

    final pendingResponse = await apiClient.postJson('/v1/backups', {
      'deviceId': deviceId,
      'sha256': sha256.convert(bytes).toString(),
      'sizeBytes': bytes.length,
      'formatVersion': formatVersion,
    });
    final pending = _jsonObject(pendingResponse.decodeJson());
    final backupId = pending['backupId'];
    if (backupId is! String || backupId.isEmpty) {
      throw const FormatException('Backup API did not return an identifier.');
    }

    await apiClient.request(
      'PUT',
      '/v1/backups/$backupId/content',
      body: bytes,
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Content-SHA256': sha256.convert(bytes).toString(),
      },
      requestTimeout: const Duration(minutes: 2),
    );
    final finalizeResponse = await apiClient.postJson(
      '/v1/backups/$backupId/finalize',
      const <String, dynamic>{},
    );
    final finalized = _jsonObject(finalizeResponse.decodeJson());
    if (finalized['status'] != 'verified' ||
        finalized['sha256'] != sha256.convert(bytes).toString()) {
      throw const FormatException('Server did not verify the uploaded backup.');
    }
    final verifiedAt = DateTime.tryParse(
      finalized['verifiedAt'] as String? ?? '',
    );
    if (verifiedAt == null) {
      throw const FormatException(
        'Server returned an invalid verification time.',
      );
    }
    return RemoteBackupReceipt(
      backupId: backupId,
      checksum: checksum,
      verifiedAt: verifiedAt,
    );
  }

  /// Adds missing documents and keeps conflicting versions as numbered copies.
  /// Account sync history takes precedence over an older device snapshot.
  Future<bool> hydrateFromLatestAccountBackup() async {
    final userId = session.userId;
    if (!session.isSignedIn || userId == null) {
      throw StateError('Account backup recovery requires sign-in.');
    }
    final suffix = sha256
        .convert(utf8.encode(userId))
        .toString()
        .substring(0, 16);
    final hydrationKey = 'account_backup_hydrated_$suffix.json';
    final listing = _jsonObject(
      (await apiClient.get('/v1/backups')).decodeJson(),
    );
    final backups = listing['backups'];
    if (backups is! List<dynamic>) {
      throw const FormatException('Malformed account backup listing.');
    }
    if (backups.isEmpty) {
      return false;
    }
    final latest = _jsonObject(backups.first);
    final backupId = latest['backupId'];
    final expectedHash = latest['sha256'];
    final expectedSize = latest['sizeBytes'];
    if (backupId is! String ||
        !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(backupId) ||
        expectedHash is! String ||
        expectedSize is! int ||
        expectedSize > maximumSnapshotBytes ||
        expectedSize <= 0) {
      throw const FormatException('Invalid verified backup metadata.');
    }

    final bytes = (await apiClient.request(
      'GET',
      '/v1/backups/$backupId/download',
      requestTimeout: const Duration(minutes: 2),
      maxResponseBytes: maximumSnapshotBytes,
    )).bodyBytes;
    if (session.userId != userId ||
        bytes.length != expectedSize ||
        sha256.convert(bytes).toString() != expectedHash) {
      throw const FormatException('Account backup integrity check failed.');
    }
    final envelope = _jsonObject(jsonDecode(utf8.decode(bytes)));
    if (envelope['format'] != 'nanotateczki-server-backup' ||
        envelope['version'] != formatVersion ||
        envelope['checksumAlgorithm'] != 'sha256' ||
        envelope['deviceId'] != latest['deviceId']) {
      throw const FormatException('Unsupported account backup envelope.');
    }
    final payload = _jsonObject(envelope['payload']);
    final wireChecksum = sha256.convert(backupPayloadBytes(bytes)).toString();
    if (wireChecksum != envelope['checksum'] &&
        sha256.convert(utf8.encode(jsonEncode(payload))).toString() !=
            envelope['checksum']) {
      throw const FormatException('Account backup payload was modified.');
    }
    final rawNotebooks = payload['notebooks'];
    if (rawNotebooks is! List<dynamic> ||
        payload['libraryState'] is! Map<String, dynamic> ||
        payload['studyPlannerState'] is! Map<String, dynamic>) {
      throw const FormatException('Incomplete account backup.');
    }
    final recoveredNotebooks = repository.decodeBackupStrict(rawNotebooks);
    // Check the newest verified snapshot at every sign-in, including when
    // this device already restored an older one. Reprocessing the same
    // snapshot would create duplicate numbered conflict copies.
    final previousHydration = await readStoredText(hydrationKey);
    String? previousBackupId;
    if (previousHydration != null) {
      try {
        final previous = jsonDecode(previousHydration);
        if (previous is Map<String, dynamic> &&
            previous['version'] == 1 &&
            previous['backupId'] is String) {
          previousBackupId = previous['backupId'] as String;
        }
      } on FormatException {
        // An invalid checkpoint must not prevent account recovery.
      }
    }
    if (previousBackupId == backupId &&
        (recoveredNotebooks.isEmpty ||
            (await repository.fetchNotebooks()).isNotEmpty)) {
      return false;
    }
    if (session.userId != userId) {
      return false;
    }

    var changed = false;
    final local = await repository.fetchNotebooks();
    final recoveredUids = <String, String>{};
    final recoveredLibrary = _jsonObject(payload['libraryState']);
    final localLibrary = _jsonObject(
      _decodeOptionalObject(await readStoredText('library_folders.json')),
    );
    // The sync journal, including tombstones, takes precedence over backup.
    // Replaying a snapshot after a deletion would resurrect old documents.
    if (recoveredNotebooks.isNotEmpty) {
      final bootstrap = _jsonObject(
        (await apiClient.get('/v1/sync/bootstrap')).decodeJson(),
      );
      final records = bootstrap['notebooks'];
      final cursor = bootstrap['cursor'];
      if (records is! List<dynamic> || cursor is! num) {
        throw const FormatException('Malformed sync bootstrap response.');
      }
      // An empty historic feed may have compacted tombstones; never replay it.
      if (records.isNotEmpty || cursor == 0) {
        final authoritative = {
          for (final raw in records) _jsonObject(raw)['uid']: _jsonObject(raw),
        };
        final remoteNotes = repository.decodeBackupStrict([
          for (final record in authoritative.values)
            if (record['deleted'] != true) record['notebook'],
        ]);
        final remoteByUid = {for (final note in remoteNotes) note.uid: note};
        final imports = <Notebook>[];
        for (final recovered in recoveredNotebooks) {
          if (authoritative[recovered.uid]?['deleted'] == true) {
            continue;
          }
          final existing = local.where((note) => note.uid == recovered.uid);
          final sameTasks =
              recovered.kind != NotebookKind.planner ||
              jsonEncode(_plannerTasks(localLibrary, recovered.uid)) ==
                  jsonEncode(_plannerTasks(recoveredLibrary, recovered.uid));
          if (existing.isNotEmpty &&
              sameTasks &&
              _sameContent(existing.first, recovered)) {
            continue;
          }
          final remote = remoteByUid[recovered.uid];
          if (remote != null &&
              _sameContent(remote, recovered) &&
              (sameTasks || existing.isEmpty)) {
            // Sync will supply this document; only missing task state needs recovery.
            if (existing.isEmpty) {
              recoveredUids[recovered.uid] = recovered.uid;
            }
            continue;
          }
          final occupied = [...local, ...remoteNotes, ...imports];
          final conflicts =
              existing.isNotEmpty ||
              remote != null ||
              occupied.any(
                (note) =>
                    note.folder == recovered.folder &&
                    note.title == recovered.title,
              );
          final incoming = conflicts
              ? numberedNotebookCopy(recovered, occupied)
              : recovered;
          imports.add(incoming);
          recoveredUids[recovered.uid] = incoming.uid;
        }
        if (session.userId != userId || !session.isSignedIn) {
          return false;
        }
        if (imports.isNotEmpty) {
          await repository.importNotebooksAtomically(imports);
          changed = true;
        }
      }
    }
    changed =
        await _mergeLibraryState(recoveredLibrary, recoveredUids) || changed;
    changed =
        await _restoreAccountFile(
          'study_planner.json',
          payload['studyPlannerState'],
          allowEmptyPlanner: true,
        ) ||
        changed;
    changed =
        await _restoreAccountFile(
          'app_prefs.json',
          payload['appPreferences'],
        ) ||
        changed;
    changed =
        await _restoreAccountFile(
          'editor_prefs.json',
          payload['editorPreferences'],
        ) ||
        changed;
    changed =
        await _restoreAccountFile(
          'shared_recent_colors.json',
          payload['recentColors'],
        ) ||
        changed;
    changed =
        await _restoreAccountFile(
          _backupPreferenceKey(userId),
          payload['backupPreferences'],
        ) ||
        changed;
    if (session.userId == userId) {
      await writeStoredText(
        hydrationKey,
        jsonEncode({'version': 1, 'backupId': backupId}),
      );
    }
    return changed;
  }

  static String _backupPreferenceKey(String userId) {
    final suffix = sha256
        .convert(utf8.encode(userId))
        .toString()
        .substring(0, 16);
    return 'server_backup_preferences_$suffix.json';
  }

  static Object _plannerTasks(Map<String, dynamic> library, String uid) {
    final tasks = library['plannerTasks'];
    return tasks is Map ? tasks[uid] ?? const [] : const [];
  }

  static Future<bool> _mergeLibraryState(
    Map<String, dynamic> recovered,
    Map<String, String> recoveredUids,
  ) async {
    if (recovered.isEmpty) {
      return false;
    }
    final current = _jsonObject(
      _decodeOptionalObject(await readStoredText('library_folders.json')),
    );
    final merged = <String, dynamic>{...recovered, ...current};
    for (final field in ['folders', 'recentCoverColors']) {
      if (recovered[field] is List) {
        merged[field] = {
          if (current[field] is List) ...current[field] as List,
          ...recovered[field] as List,
        }.toList();
      }
    }
    if (recovered['covers'] is Map) {
      merged['covers'] = {
        ...recovered['covers'] as Map,
        if (current['covers'] is Map) ...current['covers'] as Map,
      };
    }
    final tasks = <String, dynamic>{
      if (current['plannerTasks'] is Map)
        ...Map<String, dynamic>.from(current['plannerTasks'] as Map),
    };
    for (final entry in recoveredUids.entries) {
      if (!tasks.containsKey(entry.value)) {
        tasks[entry.value] = _plannerTasks(recovered, entry.key);
      }
    }
    if (current['plannerTasks'] is Map || recovered['plannerTasks'] is Map) {
      merged['plannerTasks'] = tasks;
    }
    if (jsonEncode(merged) == jsonEncode(current)) {
      return false;
    }
    await writeStoredText('library_folders.json', jsonEncode(merged));
    return true;
  }

  static bool _sameContent(Notebook left, Notebook right) {
    Map<String, dynamic> comparable(Notebook note) {
      final encoded = NotebookRepository.encodeNotebook(note)
        ..remove('createdAt')
        ..remove('updatedAt');
      for (final page in encoded['pages'] as List) {
        for (final image in page['imageBlocks'] as List) {
          if (image['bytes'] is String &&
              (image['bytes'] as String).isNotEmpty) {
            image['path'] = '';
          }
        }
      }
      return encoded;
    }

    return jsonEncode(comparable(left)) == jsonEncode(comparable(right));
  }

  static List<int> _decodeRecentColors(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List<dynamic> || decoded.any((item) => item is! int)) {
      throw const FormatException('Invalid recent color history.');
    }
    return decoded.cast<int>().take(12).toList();
  }

  static Future<bool> _restoreAccountFile(
    String key,
    Object? value, {
    bool allowDefaultFolders = false,
    bool allowEmptyPlanner = false,
  }) async {
    if (value == null ||
        (value is Map && value.isEmpty) ||
        (value is List && value.isEmpty)) {
      return false;
    }
    final stored = await readStoredText(key);
    if (stored != null && stored.trim().isNotEmpty) {
      if (!allowDefaultFolders && !allowEmptyPlanner) {
        return false;
      }
      try {
        final previous = jsonDecode(stored);
        if (allowDefaultFolders) {
          if (previous is! Map ||
              previous['folders'] is! List ||
              (previous['folders'] as List).any(
                (folder) => folder != 'Notes',
              ) ||
              (previous['plannerTasks'] is Map &&
                  (previous['plannerTasks'] as Map).isNotEmpty) ||
              (previous['covers'] is Map &&
                  (previous['covers'] as Map).isNotEmpty) ||
              (previous['recentCoverColors'] is List &&
                  (previous['recentCoverColors'] as List).isNotEmpty)) {
            return false;
          }
        }
        if (allowEmptyPlanner &&
            (previous is! Map ||
                previous['sessions'] is! List ||
                (previous['sessions'] as List).isNotEmpty)) {
          return false;
        }
      } catch (_) {
        // Unknown local state is not overwritten.
        return false;
      }
    }
    await writeStoredText(key, jsonEncode(value));
    return true;
  }

  static Object _decodeOptionalObject(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Application state is not a JSON object.');
    }
    return decoded;
  }

  static Map<String, dynamic> _jsonObject(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Server returned malformed JSON.');
    }
    return raw;
  }
}

({String checksum, Uint8List bytes}) _encodeSnapshot(
  Map<String, dynamic> data,
) {
  final payload = data['payload'] as Map<String, dynamic>;
  final deviceId = data['deviceId'] as String;
  final checksum = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  final envelope = <String, dynamic>{
    'format': 'nanotateczki-server-backup',
    'version': RemoteBackupService.formatVersion,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'deviceId': deviceId,
    'checksumAlgorithm': 'sha256',
    'checksum': checksum,
    'payload': payload,
  };
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  return (checksum: checksum, bytes: bytes);
}
