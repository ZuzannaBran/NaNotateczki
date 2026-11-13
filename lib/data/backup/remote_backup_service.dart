import 'dart:convert';

import 'package:crypto/crypto.dart';

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

  static const int maximumSnapshotBytes = 64 * 1024 * 1024;

  final NotebookRepository repository;
  final ApiClient apiClient;
  final AccountSessionController session;

  static String _databasePresenceKey(String userId) {
    final suffix = sha256
        .convert(utf8.encode(userId))
        .toString()
        .substring(0, 16);
    return 'account_database_present_$suffix.json';
  }

  /// A missing SQLite file is data loss only if the account used it before.
  /// An empty but existing database is never interpreted as lost data.
  Future<bool> wasDatabaseInitialized(String userId) async {
    final raw = await readStoredText(_databasePresenceKey(userId));
    if (raw == null) {
      return false;
    }
    final marker = jsonDecode(raw);
    if (marker is! Map<String, dynamic> || marker['version'] != 1) {
      throw const FormatException('Invalid account database presence marker.');
    }
    return true;
  }

  Future<void> markDatabaseInitialized(String userId) async {
    if (!session.isSignedIn || session.userId != userId) {
      throw StateError('Account changed before database marker write.');
    }
    await writeStoredText(
      _databasePresenceKey(userId),
      jsonEncode({'version': 1}),
    );
  }
}
