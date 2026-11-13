import 'dart:convert';

import 'package:collection/collection.dart';

import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import 'api_client.dart';
import 'live_web_sync_service.dart';

/// Move a proved legacy projection into a protected SQLite archive, then
/// let the standard checkpointed operation feed rebuild the live projection.
class LegacyV2ProjectionCutover {
  LegacyV2ProjectionCutover({
    required this.repository,
    required this.apiClient,
    required this.accountId,
    required this.isCurrent,
  });

  final NotebookRepository repository;
  final ApiClient apiClient;
  final String accountId;
  final bool Function() isCurrent;

  static const _tables = [
    'notebook_rows',
    'page_rows',
    'ink_stroke_rows',
    'text_block_rows',
    'image_block_rows',
  ];

  void _assertCurrent() {
    if (!isCurrent()) {
      throw StateError('Account changed during legacy cutover.');
    }
  }

  Future<void> prepare(LegacyCutoverReceipt receipt) async {
    _assertCurrent();
    await repository.waitForPendingSaves();
    final database = repository.database;
    await database.transaction(() async {
      _assertCurrent();
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS legacy_v1_projection_cutover ('
        'account_id TEXT PRIMARY KEY, legacy_cursor INTEGER NOT NULL, '
        'operation_cursor INTEGER NOT NULL, library_json TEXT)',
      );
      final marker = await database
          .customSelect('SELECT * FROM legacy_v1_projection_cutover')
          .getSingleOrNull();
      if (marker != null) {
        if (marker.read<String>('account_id') != accountId ||
            marker.read<int>('legacy_cursor') != receipt.legacyCursor ||
            marker.read<int>('operation_cursor') != receipt.operationCursor) {
          throw StateError('Historical cutover receipt changed.');
        }
        return;
      }
      final journal = await database
          .customSelect('SELECT COUNT(*) AS total FROM operations')
          .getSingle();
      if (journal.read<int>('total') != 0) {
        throw StateError('Historical cutover cannot replace a v2 journal.');
      }
      final localState = await LiveWebSyncService.readCutoverState(accountId);
      if (localState.cursor > receipt.legacyCursor) {
        throw StateError('Legacy device cursor is newer than the cutover.');
      }
      final notebooks = await repository.fetchNotebooksForCutover();
      if (repository.lastFetchSkippedCorruptRows) {
        throw StateError('Corrupt local notebook blocks historical cutover.');
      }
      for (final notebook in notebooks) {
        _assertCurrent();
        final revision = localState.revisions[notebook.uid];
        if (revision == null) {
          throw StateError('An unacknowledged legacy notebook blocks cutover.');
        }
        final response = await apiClient.get(
          '/v2/activation/legacy-source',
          query: {'uid': notebook.uid, 'revision': '$revision'},
        );
        final source = response.decodeJson();
        if (source is! Map<String, dynamic> ||
            source['revision'] != revision ||
            source['notebook'] is! Map<String, dynamic>) {
          throw const FormatException('Invalid archived legacy revision.');
        }
        final remote = repository.decodeBackupStrict([
          source['notebook'],
        ]).single;
        if (remote.pages.any(
          (page) =>
              page.imageBlocks.any((image) => image.bytes?.isNotEmpty != true),
        )) {
          // Never resolve paths from archived server snapshots on a client.
          throw StateError('Archived legacy revision has unverified media.');
        }
        final localValue = LiveWebSyncService.encodeCutoverNotebook(notebook);
        final remoteValue = LiveWebSyncService.encodeCutoverNotebook(remote);
        // Drift persisted whole seconds in v1. Compare within the same
        // stored second while requiring exact equality of notebook content.
        for (final field in ['createdAt', 'updatedAt']) {
          final localTime = DateTime.parse(localValue[field] as String);
          final remoteTime = DateTime.parse(remoteValue[field] as String);
          if (localTime.millisecondsSinceEpoch ~/ 1000 ==
              remoteTime.millisecondsSinceEpoch ~/ 1000) {
            localValue[field] = remoteValue[field];
          }
        }
        if (!const DeepCollectionEquality().equals(localValue, remoteValue)) {
          throw StateError('Unsent legacy notebook changes block cutover.');
        }
      }
      final library = await readStoredText('library_folders.json');
      final response = await apiClient.get('/v2/activation/legacy-library');
      final source = response.decodeJson();
      if (source is! Map<String, dynamic> ||
          !source.containsKey('library') ||
          (source['library'] != null && source['library'] is! Map)) {
        throw const FormatException('Invalid archived legacy library.');
      }
      final remoteLibrary = source['library'];
      if (library != null &&
          library.isNotEmpty &&
          !_equivalentLibrary(jsonDecode(library), remoteLibrary)) {
        throw StateError('Unsent legacy folder or task changes block cutover.');
      }
      _assertCurrent();
      for (final table in _tables) {
        // Keep raw rows, including inline bytes and legacy-only fields, in
        // the same transaction as the marker and removal of the live copy.
        await database.customStatement(
          'CREATE TABLE legacy_v1_$table AS SELECT * FROM $table',
        );
      }
      for (final table in _tables.reversed) {
        await database.customStatement('DELETE FROM $table');
      }
      await database.customStatement(
        'INSERT INTO legacy_v1_projection_cutover VALUES (?, ?, ?, ?)',
        [
          accountId,
          receipt.legacyCursor,
          receipt.operationCursor,
          remoteLibrary == null ? null : jsonEncode(remoteLibrary),
        ],
      );
      _assertCurrent();
    });
  }

  static bool _equivalentLibrary(Object? local, Object? remote) {
    Map<String, dynamic>? normalize(Object? value) {
      if (value == null) {
        return {
          'folders': <String>[],
          'covers': <String, dynamic>{},
          'plannerTasks': <String, dynamic>{},
          'recentCoverColors': <int>[],
        };
      }
      final parsed = value is List ? {'folders': value} : value;
      if (parsed is! Map || parsed['folders'] is! List) {
        return null;
      }
      final folders = parsed['folders'] as List;
      if (folders.any((item) => item is! String)) {
        return null;
      }
      return {
        ...normalize(null)!,
        ...Map<String, dynamic>.from(parsed),
        'folders': folders.cast<String>().toSet().toList()..sort(),
      };
    }

    final left = normalize(local);
    final right = normalize(remote);
    return left != null &&
        right != null &&
        const DeepCollectionEquality().equals(left, right);
  }
}
