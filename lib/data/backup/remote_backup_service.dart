import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/storage/app_save_coordinator.dart';
import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../sync/account_session_controller.dart';
import '../sync/api_client.dart';

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
    await AppSaveCoordinator.instance.flushPending();
    await repository.waitForPendingSaves();
    final notebooks = await repository.fetchNotebooks();
    if (repository.lastFetchSkippedCorruptRows) {
      throw StateError('Remote backup refused unreadable notebook data.');
    }

    final libraryState = await readStoredText('library_folders.json');
    final studyPlannerState = await readStoredText('study_planner.json');
    final payload = <String, dynamic>{
      'notebooks': repository.encodeSelfContainedBackup(notebooks),
      'libraryState': _decodeOptionalObject(libraryState),
      'studyPlannerState': _decodeOptionalObject(studyPlannerState),
    };
    final checksum = sha256
        .convert(utf8.encode(jsonEncode(payload)))
        .toString();
    final envelope = <String, dynamic>{
      'format': 'nanotateczki-server-backup',
      'version': formatVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'deviceId': deviceId,
      'checksumAlgorithm': 'sha256',
      'checksum': checksum,
      'payload': payload,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
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
