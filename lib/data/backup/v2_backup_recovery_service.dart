import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/storage/app_save_coordinator.dart';
import '../../core/storage/active_storage_namespace.dart';
import '../../core/storage/storage_namespace_manager.dart';
import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../sync/account_session_controller.dart';
import '../sync/api_client.dart';
import '../sync/editor_v2_account_runtime.dart';
import '../sync/operation_gateway.dart';
import '../sync/operation_protocol.dart';
import 'backup_payload_bytes.dart';
import 'remote_backup_service.dart';

/// An immutable, server-verified operational archive, never a v1 document
/// writer. Recovery replays the original envelopes through the v2 reducers.
class V2BackupRecoveryService {
  V2BackupRecoveryService({
    required this.runtime,
    required this.repository,
    required this.apiClient,
    required this.session,
  });

  static const formatVersion = 3;
  static const _maximumEntries = 100000;
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _uuidPattern = RegExp(
    r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-'
    r'[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
  );

  final EditorV2AccountRuntime runtime;
  final NotebookRepository repository;
  final ApiClient apiClient;
  final AccountSessionController session;

  /// Test-only failure injection at the boundary between durable operations.
  @visibleForTesting
  Future<void> Function(int replayed)? afterRecoveryOperation;

  String get _accountId {
    final id = session.userId;
    if (!session.isSignedIn || id == null || id.isEmpty) {
      throw StateError('Operational backup requires a signed-in account.');
    }
    return id;
  }

  String get _scope => 'account:${_accountId}';

  void _assertAccount(String id) {
    if (_accountId != id ||
        ActiveStorageNamespace.current != StorageNamespace.account(id)) {
      throw StateError('Account namespace changed during v2 backup.');
    }
  }

  String _marker(String userId) =>
      'v2_backup_recovery_${sha256.convert(utf8.encode(userId)).toString().substring(0, 16)}.json';

  Future<bool> hasInterruptedRecovery(String userId) async {
    final saved = await readStoredText(_marker(userId));
    if (saved == null) {
      return false;
    }
    final decoded = jsonDecode(saved);
    if (decoded is! Map || decoded['version'] != 1) {
      throw const FormatException('Invalid recovery marker.');
    }
    return decoded['state'] == 'pending';
  }

  Future<void> completeRecovery() async {
    final id = _accountId;
    final raw = await readStoredText(_marker(id));
    if (raw == null) {
      return;
    }
    final record = _asObject(jsonDecode(raw));
    if (record['state'] != 'pending') {
      return;
    }
    await writeStoredText(_marker(id), jsonEncode({
      ...record,
      'state': 'complete',
    }));
  }

  Future<RemoteBackupReceipt> uploadVerifiedSnapshot({
    required String deviceId,
  }) async {
    final accountId = _accountId;
    _assertAccount(accountId);
    if (!_uuidPattern.hasMatch(deviceId)) {
      throw const FormatException('Backup device ID must be a UUID.');
    }
    await runtime.engine.syncNow();
    if (runtime.engine.lastError != null) {
      throw StateError('Cannot back up an unresolved v2 synchronization.');
    }
    await AppSaveCoordinator.instance.flushPending();
    await repository.waitForPendingSaves();

    _assertAccount(accountId);
    final files = await _readAccountFiles(accountId);
    final checkpoint = await _serverCursor();
    late final int localCursor;
    await repository.database.transaction(() async {
      final pending = await repository.database.customSelect(
        'SELECT COUNT(*) AS total FROM operation_outbox',
      ).getSingle();
      if (pending.read<int>('total') != 0) {
        throw StateError('Backup postponed until the v2 outbox is ACKed.');
      }
      localCursor = await runtime.store.checkpoint(_scope);
      if (localCursor != checkpoint) {
        throw StateError('Server history is not yet fully applied.');
      }
      final rows = await repository.database.customSelect(
        'PRAGMA quick_check',
      ).get();
      if (rows.length != 1 || rows.single.data.values.single != 'ok') {
        throw StateError('Local database integrity check failed.');
      }
    });

    // The server's authenticated feed is the authority for all ACKed events,
    // including those from other devices and actor echoes.
    final feed = HttpOperationGateway(apiClient);
    final history = <Map<String, dynamic>>[];
    final receipts = <String, Map<String, dynamic>>{};
    var after = 0;
    while (after < checkpoint) {
      _assertAccount(accountId);
      final page = await feed.readAfter(after);
      if (!page.verifiedVisiblePrefix ||
          page.operations.isEmpty ||
          page.cursor <= after ||
          page.cursor > checkpoint) {
        throw const FormatException('Backup feed has an incomplete frontier.');
      }
      for (final item in page.operations) {
        if (item.cursor <= after || item.cursor > checkpoint) {
          throw const FormatException('Invalid backup operation sequence.');
        }
        history.add({
          'cursor': item.cursor,
          'operation': item.operation.toJson(),
        });
        if (item.operation.kind == OperationKind.assetAttach) {
          final receipt = item.operation.payload;
          final digest = receipt['sha256'] as String;
          if (receipts.containsKey(digest) &&
              (receipts[digest]!['sizeBytes'] != receipt['sizeBytes'] ||
                  receipts[digest]!['mediaType'] != receipt['mediaType'])) {
            throw const FormatException('Conflicting asset receipts.');
          }
          receipts[digest] = receipt;
        }
      }
      after = page.cursor;
      if (history.length > _maximumEntries) {
        throw StateError('V2 history exceeds the full-archive safety budget.');
      }
    }
    if (after != checkpoint) {
      throw const FormatException('Backup feed did not reach its checkpoint.');
    }

    // Verified content-addressed assets are stored once by the v2 server.
    // Do not duplicate unchanged PDFs/images in each new backup envelope.
    // Server finalize checks that every referenced digest is still durable.
    final assetBlobs = <String, Map<String, dynamic>>{
      for (final entry in receipts.entries)
        entry.key: {
          'sizeBytes': entry.value['sizeBytes'],
          'mediaType': entry.value['mediaType'],
          'storage': 'verified-v2',
        },
    };
    _assertAccount(accountId);
    if (await runtime.store.checkpoint(_scope) != localCursor ||
        await _serverCursor() != checkpoint ||
        !await _unchangedAccountFiles(accountId, files) ||
        (await runtime.store.pending(limit: 1, includeDeferred: true))
            .isNotEmpty) {
      throw StateError('V2 account changed during backup capture.');
    }

    final payload = <String, dynamic>{
      // The operational journal, not a second serialized notebook writer,
      // owns complete documents, tombstones, layers and Quill deltas.
      'notebooks': <dynamic>[],
      'operationHistory': history,
      'assetBlobs': assetBlobs,
      'libraryState': _decodeObject(files['library_folders.json']),
      'studyPlannerState': _decodeObject(files['study_planner.json']),
      'appPreferences': _decodeObject(files['app_prefs.json']),
      'editorPreferences': _decodeObject(files['editor_prefs.json']),
      'recentColors': files['shared_recent_colors.json'] == null
          ? <dynamic>[]
          : _decodeColors(files['shared_recent_colors.json']!),
      'backupPreferences':
          _decodeObject(files[_backupPreferenceKey(accountId)]),
    };
    final encoded = await compute(_encodeOperationalArchive, {
      'payload': payload,
      'accountId': accountId,
      'deviceId': deviceId,
      'schemaVersion': repository.database.schemaVersion,
      'checkpoint': {_scope: checkpoint},
    });
    final bytes = encoded.bytes;
    if (bytes.length > RemoteBackupService.maximumSnapshotBytes) {
      throw StateError('V2 archive exceeds the 64 MiB backup safety limit.');
    }
    _assertAccount(accountId);
    if (await runtime.store.checkpoint(_scope) != checkpoint ||
        (await runtime.store.pending(limit: 1, includeDeferred: true))
            .isNotEmpty) {
      throw StateError('V2 operations changed before backup upload.');
    }
    final hash = sha256.convert(bytes).toString();
    _assertAccount(accountId);
    final created = _asObject((await apiClient.postJson('/v2/backups', {
      'deviceId': deviceId,
      'sha256': hash,
      'sizeBytes': bytes.length,
      'formatVersion': formatVersion,
    })).decodeJson());
    final backupId = created['backupId'];
    if (backupId is! String || !_uuidPattern.hasMatch(backupId)) {
      throw const FormatException('Invalid v2 backup identifier.');
    }
    _assertAccount(accountId);
    await apiClient.request(
      'PUT',
      '/v2/backups/$backupId/content',
      body: bytes,
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Content-SHA256': hash,
      },
      requestTimeout: const Duration(minutes: 2),
    );
    _assertAccount(accountId);
    final result = _asObject((await apiClient.postJson(
      '/v2/backups/$backupId/finalize',
      const <String, dynamic>{},
    )).decodeJson());
    if (result['status'] != 'verified' || result['sha256'] != hash) {
      throw const FormatException('Operational archive not verified.');
    }
    final verifiedAt = DateTime.tryParse(result['verifiedAt'] as String? ?? '');
    if (verifiedAt == null) {
      throw const FormatException('Invalid v2 backup timestamp.');
    }
    return RemoteBackupReceipt(
      backupId: backupId,
      checksum: encoded.checksum,
      verifiedAt: verifiedAt,
    );
  }

  /// Restores a verified immutable archive before starting SyncEngine.
  /// A failed or interrupted replay retains the pending marker and cursor.
  Future<bool> recoverVerifiedArchive({required bool databaseWasReset}) async {
    final accountId = _accountId;
    _assertAccount(accountId);
    final listing = _asObject((await apiClient.get('/v2/backups')).decodeJson());
    final backups = listing['backups'];
    if (backups is! List<dynamic>) {
      throw const FormatException('Invalid v2 backup listing.');
    }
    if (backups.isEmpty) {
      if (await hasInterruptedRecovery(accountId)) {
        throw StateError('Pending recovery has no verified backup.');
      }
      return false;
    }
    final markerKey = _marker(accountId);
    final earlier = await readStoredText(markerKey);
    final pending = earlier == null
        ? null
        : _asObject(jsonDecode(earlier));
    if (pending != null &&
        pending['state'] == 'pending' &&
        (pending['backupId'] is! String)) {
      throw const FormatException('Invalid pending recovery identity.');
    }

    final chosen = pending != null && pending['state'] == 'pending'
        ? backups.where((entry) =>
            entry is Map && entry['backupId'] == pending['backupId']).toList()
        : backups;
    if (chosen.isEmpty) {
      throw StateError('Pending v2 recovery archive is unavailable.');
    }
    _assertAccount(accountId);
    final verified = await _downloadValidArchive(chosen, accountId);
    final backupId = verified.id;
    final archiveCursor = verified.cursor;
    if (pending != null &&
        pending['state'] == 'pending' &&
        pending['backupId'] != backupId) {
      throw StateError('Recovery snapshot changed during restart.');
    }
    final localCursor = await runtime.store.checkpoint(_scope);
    if (!databaseWasReset && localCursor > archiveCursor) {
      throw StateError('Older backup cannot roll back the v2 checkpoint.');
    }
    if ((await runtime.store.pending(limit: 1, includeDeferred: true))
        .isNotEmpty) {
      throw StateError('Local pending edits block archive recovery.');
    }
    if (pending == null || pending['state'] != 'pending') {
      final oldJournal = await repository.database.customSelect(
        'SELECT COUNT(*) AS total FROM operations',
      ).getSingle();
      if (oldJournal.read<int>('total') != 0) {
        throw StateError('Archive recovery requires a fresh v2 journal.');
      }
    }
    _assertAccount(accountId);
    await writeStoredText(markerKey, jsonEncode({
      'version': 1,
      'state': 'pending',
      'backupId': backupId,
      'checkpoint': archiveCursor,
    }));

    final assets = verified.assets;
    var previous = 0;
    var replayed = 0;
    for (final item in verified.history) {
      _assertAccount(accountId);
      final cursor = item.cursor;
      final operation = item.operation;
      if (cursor <= previous || cursor > archiveCursor) {
        throw const FormatException('Non-monotonic archived cursor.');
      }
      previous = cursor;
      if (operation.kind == OperationKind.assetAttach) {
        final digest = operation.payload['sha256'];
        final bytes = assets[digest];
        if (bytes == null) {
          throw const FormatException('Missing archived asset.');
        }
        runtime.projector.verifiedAssetBuffer!.stage(
          receipt: operation.payload,
          bytes: bytes,
        );
      }
      await runtime.store.applyRemote(
        operation,
        checkpointScope: _scope,
        serverSequence: cursor,
        coveredCursor: cursor - 1,
        apply: () => operation.documentId ==
                OperationEnvelope.libraryDocumentId
            ? runtime.libraryOperations.apply(operation)
            : runtime.projector.apply(operation),
      );
      replayed++;
      await afterRecoveryOperation?.call(replayed);
    }
    if (previous != archiveCursor) {
      throw const FormatException('Archive ends before the saved checkpoint.');
    }
    if (await runtime.store.checkpoint(_scope) != archiveCursor) {
      throw StateError('Operational recovery checkpoint mismatch.');
    }
    final check = await repository.database.customSelect('PRAGMA quick_check').get();
    if (check.length != 1 || check.single.data.values.single != 'ok') {
      throw StateError('Recovered SQLite integrity check failed.');
    }
    _assertAccount(accountId);
    // A read model may be rebuilt; never use a legacy snapshot as a writer.
    await runtime.libraryOperations.refreshReadModel();
    for (final entry in verified.files.entries) {
      if (entry.value == null) {
        continue;
      }
      final current = await readStoredText(entry.key);
      if (current == null || current.trim().isEmpty) {
        await writeStoredText(entry.key, entry.value!);
      }
    }
    return true;
  }

  Future<_V2Archive> _downloadValidArchive(
    List<dynamic> backups,
    String accountId,
  ) async {
    Object? failure;
    for (final raw in backups) {
      _assertAccount(accountId);
      try {
        final entry = _asObject(raw);
        final id = entry['backupId'];
        final hash = entry['sha256'];
        final size = entry['sizeBytes'];
        if (id is! String ||
            !_uuidPattern.hasMatch(id) ||
            hash is! String ||
            !_digestPattern.hasMatch(hash) ||
            size is! int ||
            size <= 0 ||
            size > RemoteBackupService.maximumSnapshotBytes) {
          throw const FormatException('Invalid verified backup metadata.');
        }
        final bytes = (await apiClient.request(
          'GET',
          '/v2/backups/$id/download',
          maxResponseBytes: RemoteBackupService.maximumSnapshotBytes,
          requestTimeout: const Duration(minutes: 2),
        )).bodyBytes;
        if (bytes.length != size || sha256.convert(bytes).toString() != hash) {
          throw const FormatException('Corrupt verified archive.');
        }
        _assertAccount(accountId);
        final envelope = _asObject(jsonDecode(utf8.decode(bytes)));
        if (envelope['format'] != 'nanotateczki-server-backup' ||
            envelope['version'] != formatVersion ||
            envelope['protocol'] != 'operations-v2' ||
            envelope['accountId'] != accountId ||
            envelope['deviceId'] != entry['deviceId'] ||
            envelope['schemaVersion'] != repository.database.schemaVersion ||
            envelope['checksumAlgorithm'] != 'sha256') {
          throw const FormatException('Incompatible account v2 archive.');
        }
        if (sha256.convert(backupPayloadBytes(bytes)).toString() !=
            envelope['checksum']) {
          throw const FormatException('Operational payload checksum mismatch.');
        }
        final checkpoint = _asObject(envelope['operationCheckpoint']);
        if (checkpoint.length != 1 ||
            checkpoint[_scope] is! int ||
            (checkpoint[_scope] as int) < 0 ||
            (checkpoint[_scope] as int) > OperationEnvelope.maxSafeInteger) {
          throw const FormatException('Invalid archive checkpoint.');
        }
        final payload = _asObject(envelope['payload']);
        final rawHistory = payload['operationHistory'];
        final rawAssets = payload['assetBlobs'];
        if (rawHistory is! List || rawAssets is! Map ||
            payload['studyPlannerState'] is! Map ||
            payload['libraryState'] is! Map) {
          throw const FormatException('Incomplete operational archive.');
        }
        final history = <SequencedOperation>[];
        final required = <String, Map<String, dynamic>>{};
        var previous = 0;
        for (final rawEntry in rawHistory) {
          final op = _asObject(rawEntry);
          final cursor = op['cursor'];
          if (cursor is! int || cursor <= previous ||
              cursor > (checkpoint[_scope] as int)) {
            throw const FormatException('Invalid archived event order.');
          }
          previous = cursor;
          final operation = OperationEnvelope.fromJson(
            _asObject(op['operation']),
          );
          operation.validateForV2Projection();
          history.add(SequencedOperation(cursor, operation));
          if (operation.kind == OperationKind.assetAttach) {
            required[operation.payload['sha256'] as String] =
                operation.payload;
          }
        }
        if (previous != checkpoint[_scope] ||
            rawAssets.length != required.length ||
            history.length > _maximumEntries) {
          throw const FormatException('Incomplete archive event frontier.');
        }
        final assets = <String, Uint8List>{};
        for (final entry in rawAssets.entries) {
          final hash = entry.key;
          if (hash is! String || !_digestPattern.hasMatch(hash) ||
              !required.containsKey(hash)) {
            throw const FormatException('Unexpected backup asset.');
          }
          final item = _asObject(entry.value);
          final receipt = required[hash]!;
          if (item['sizeBytes'] != receipt['sizeBytes'] ||
              item['mediaType'] != receipt['mediaType']) {
            throw const FormatException('Backup asset receipt mismatch.');
          }
          Uint8List bytes;
          if (item['storage'] == 'verified-v2' &&
              item.length == 3) {
            // A missing or altered remote asset is a recovery failure,
            // never a blank image or an implicitly successful restore.
            _assertAccount(accountId);
            bytes = await runtime.assetGateway.download(
              sha256: hash,
              sizeBytes: receipt['sizeBytes'] as int,
            );
          } else if (item['storage'] == null &&
              item['bytesBase64'] is String &&
              item.length == 3) {
            bytes = Uint8List.fromList(
              base64Decode(item['bytesBase64'] as String),
            );
          } else {
            throw const FormatException('Unsupported asset archive record.');
          }
          if (bytes.length != item['sizeBytes'] ||
              sha256.convert(bytes).toString() != hash) {
            throw const FormatException('Corrupted archived asset bytes.');
          }
          assets[hash] = bytes;
        }
        final files = <String, String?>{};
        for (final key in _keys(accountId)) {
          final value = switch (key) {
            'study_planner.json' => payload['studyPlannerState'],
            'app_prefs.json' => payload['appPreferences'],
            'editor_prefs.json' => payload['editorPreferences'],
            'shared_recent_colors.json' => payload['recentColors'],
            _ => key == _backupPreferenceKey(accountId)
                ? payload['backupPreferences']
                : null,
          };
          if (value != null) {
            files[key] = jsonEncode(value);
          }
        }
        return _V2Archive(
          id: id,
          cursor: checkpoint[_scope] as int,
          history: history,
          assets: assets,
          files: files,
        );
      } on FormatException catch (error) {
        failure = error;
      } on ApiException catch (error) {
        if (error.statusCode != 404 && error.statusCode != 503) {
          rethrow;
        }
        failure = error;
      }
    }
    throw FormatException('No intact operational backup: $failure');
  }

  Future<int> _serverCursor() async {
    final data = _asObject(
      (await apiClient.get('/v2/sync/checkpoint')).decodeJson(),
    );
    final cursor = data['cursor'];
    if (cursor is! int ||
        cursor < 0 ||
        cursor > OperationEnvelope.maxSafeInteger) {
      throw const FormatException('Invalid server checkpoint.');
    }
    return cursor;
  }

  static String _backupPreferenceKey(String accountId) =>
      'server_backup_preferences_${sha256.convert(utf8.encode(accountId)).toString().substring(0, 16)}.json';

  static List<String> _keys(String id) => [
    'library_folders.json',
    'study_planner.json',
    'app_prefs.json',
    'editor_prefs.json',
    'shared_recent_colors.json',
    _backupPreferenceKey(id),
  ];

  static Future<Map<String, String?>> _readAccountFiles(String id) async {
    final result = <String, String?>{};
    for (final key in _keys(id)) {
      result[key] = await readStoredText(key);
    }
    return result;
  }

  static Future<bool> _unchangedAccountFiles(
    String id,
    Map<String, String?> original,
  ) async {
    for (final key in _keys(id)) {
      if (original[key] != await readStoredText(key)) {
        return false;
      }
    }
    return true;
  }

  static Map<String, dynamic> _decodeObject(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    return _asObject(jsonDecode(raw));
  }

  static List<int> _decodeColors(String raw) {
    final value = jsonDecode(raw);
    if (value is! List ||
        value.length > 12 ||
        value.any((e) => e is! int || e < 0 || e > 0xFFFFFFFF)) {
      throw const FormatException('Invalid backup colors.');
    }
    return value.cast<int>();
  }

  static Map<String, dynamic> _asObject(Object? value) {
    if (value is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    return Map<String, dynamic>.from(value);
  }
}

class _V2Archive {
  const _V2Archive({
    required this.id,
    required this.cursor,
    required this.history,
    required this.assets,
    required this.files,
  });

  final String id;
  final int cursor;
  final List<SequencedOperation> history;
  final Map<String, Uint8List> assets;
  final Map<String, String?> files;
}

({String checksum, Uint8List bytes}) _encodeOperationalArchive(
  Map<String, dynamic> data,
) {
  final payload = data['payload'] as Map<String, dynamic>;
  final checksum = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  final envelope = <String, dynamic>{
    'format': 'nanotateczki-server-backup',
    'version': V2BackupRecoveryService.formatVersion,
    'protocol': 'operations-v2',
    'deviceId': data['deviceId'],
    'accountId': data['accountId'],
    'schemaVersion': data['schemaVersion'],
    'operationCheckpoint': data['checkpoint'],
    'checksumAlgorithm': 'sha256',
    'checksum': checksum,
    'payload': payload,
  };
  return (
    checksum: checksum,
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
  );
}
