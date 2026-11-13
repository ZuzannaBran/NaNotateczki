import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';

import '../../core/storage/text_storage.dart';
import '../../features/editor/state/editor_v2_operation_writer.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/note_page.dart';
import '../../features/notebook/domain/notebook.dart';
import 'account_settings_sync_service.dart';
import 'api_client.dart';
import 'library_v2_operation_service.dart';
import 'legacy_sync_archive.dart';
import 'notebook_merge.dart';
import 'operation_protocol.dart';
import 'operation_store.dart';

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
      final localState = await LegacySyncArchive.readCutoverState(accountId);
      if (localState.cursor > receipt.legacyCursor) {
        throw StateError('Legacy device cursor is newer than the cutover.');
      }
      final notebooks = await repository.fetchNotebooksForCutover();
      if (repository.lastFetchSkippedCorruptRows) {
        throw StateError('Corrupt local notebook blocks historical cutover.');
      }
      await _createQueue();
      final local = {
        for (final notebook in notebooks)
          notebook.uid: LegacySyncArchive.encodeCutoverNotebook(notebook),
      };
      for (final uid in {...local.keys, ...localState.pending}) {
        _assertCurrent();
        final snapshot = local[uid];
        final revision = localState.revisions[uid];
        Map<String, dynamic>? base;
        if (revision != null) {
          final response = await apiClient.get(
            '/v2/activation/legacy-source',
            query: {'uid': uid, 'revision': '$revision'},
          );
          final source = response.decodeJson();
          if (source is! Map<String, dynamic> ||
              source['revision'] != revision ||
              (source['notebook'] != null && source['notebook'] is! Map)) {
            throw const FormatException('Invalid archived legacy revision.');
          }
          if (source['notebook'] != null) {
            final remote = repository.decodeBackupStrict([
              source['notebook'],
            ]).single;
            if (remote.uid != uid ||
                remote.pages.any(
                  (page) => page.imageBlocks.any(
                    (image) => image.bytes?.isNotEmpty != true,
                  ),
                )) {
              throw StateError(
                'Archived legacy revision has unverified identity or media.',
              );
            }
            base = LegacySyncArchive.encodeCutoverNotebook(remote);
          }
        }
        if (_sameSnapshot(snapshot, base) &&
            (snapshot != null || revision != null)) {
          continue;
        }
        if (snapshot == null && !localState.pending.contains(uid)) {
          throw StateError('No durable evidence of a legacy deletion.');
        }
        await database.customStatement(
          'INSERT INTO legacy_v1_cutover_intents (uid, base_json, local_json, state) '
          "VALUES (?, ?, ?, 'pending')",
          [
            uid,
            base == null ? null : jsonEncode(base),
            snapshot == null ? null : jsonEncode(snapshot),
          ],
        );
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
        final base = await AccountSettingsSyncService.readLegacyLibraryBase(
          accountId,
        );
        await database.customStatement(
          'INSERT INTO legacy_v1_cutover_intents '
          "(uid, base_json, local_json, state) VALUES (?, ?, ?, 'pending')",
          [
            OperationEnvelope.libraryDocumentId,
            base == null ? null : jsonEncode(base),
            library,
          ],
        );
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

  Future<void> _createQueue() => repository.database.customStatement(
    'CREATE TABLE IF NOT EXISTS legacy_v1_cutover_intents ('
    'uid TEXT PRIMARY KEY, base_json TEXT, local_json TEXT, '
    'state TEXT NOT NULL, reason TEXT)',
  );

  static bool _sameSnapshot(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) {
      return a == b;
    }
    final left = Map<String, dynamic>.of(a)..remove('updatedAt');
    final right = Map<String, dynamic>.of(b)..remove('updatedAt');
    final localTime = DateTime.parse(left['createdAt'] as String);
    final remoteTime = DateTime.parse(right['createdAt'] as String);
    // Drift v1 persisted timestamps with whole-second precision.
    if (localTime.millisecondsSinceEpoch ~/ 1000 ==
        remoteTime.millisecondsSinceEpoch ~/ 1000) {
      left['createdAt'] = right['createdAt'];
    }
    return const DeepCollectionEquality().equals(left, right);
  }

  /// Applies legacy deltas only after the authoritative v2 feed is current.
  /// Conflicts preserve the original snapshot and deletion intent for review.
  Future<void> replayPending({
    required EditorV2OperationWriter writer,
    required OperationStore store,
    LibraryV2OperationService? library,
  }) async {
    await _createQueue();
    final db = repository.database;
    final rows = await db
        .customSelect(
          'SELECT uid, base_json, local_json FROM legacy_v1_cutover_intents '
          "WHERE state = 'pending' ORDER BY uid = '@library', uid",
        )
        .get();
    for (final row in rows) {
      _assertCurrent();
      final uid = row.read<String>('uid');
      if (uid == OperationEnvelope.libraryDocumentId) {
        if (library != null) {
          await _replayLibrary(library, row);
        }
        continue;
      }
      final rawBase = row.readNullable<String>('base_json');
      final rawLocal = row.readNullable<String>('local_json');
      final base = rawBase == null
          ? null
          : jsonDecode(rawBase) as Map<String, dynamic>;
      final local = rawLocal == null
          ? null
          : jsonDecode(rawLocal) as Map<String, dynamic>;
      final notebook = await repository.getNotebook(uid);
      if (repository.lastCorruptNotebookIds.contains(uid)) {
        throw StateError(
          'The v2 notebook cannot be read safely during cutover.',
        );
      }
      final current = notebook == null
          ? null
          : LegacySyncArchive.encodeCutoverNotebook(notebook);
      final tombstoned = await store.isTombstoned(uid, 'document', uid);
      Future<void> mark(String state, [String? reason]) => db.customStatement(
        'UPDATE legacy_v1_cutover_intents SET state = ?, reason = ? WHERE uid = ?',
        [state, reason, uid],
      );
      Future<void> record(List<OperationEnvelope> operations) async {
        _assertCurrent();
        await mark('converted');
      }

      Future<void> convert(Future<void> Function() apply) async {
        try {
          await apply();
        } on UnsupportedError {
          _assertCurrent();
          await mark(
            'conflict',
            'The legacy edit uses an unsupported v2 format.',
          );
        } on FormatException {
          _assertCurrent();
          await mark(
            'conflict',
            'The legacy edit could not be validated for v2.',
          );
        } on ArgumentError {
          _assertCurrent();
          await mark(
            'conflict',
            'The legacy edit cannot be represented as v2 operations.',
          );
        }
      }

      _assertCurrent();
      if (_sameSnapshot(local, current)) {
        await mark('converted');
        continue;
      }
      if (local == null) {
        final hasPostMigrationChanges = await _hasPostMigrationChanges(uid);
        if (current != null &&
            base != null &&
            !hasPostMigrationChanges &&
            _sameSnapshot(base, current)) {
          await writer.writeDeleteNotebook(
            documentId: uid,
            onCommittedInTransaction: record,
          );
        } else {
          await mark(
            'conflict',
            'A newer version exists for a locally deleted notebook.',
          );
        }
        continue;
      }
      if (current == null) {
        if (tombstoned || base != null) {
          await mark(
            'conflict',
            'The notebook was deleted remotely. Local edits were archived.',
          );
        } else {
          await convert(() async {
            await writer.writeCreateNotebook(
              notebook: _stageLegacyEmbeds(
                writer,
                repository.decodeBackupStrict([local]).single,
              ),
              onCommittedInTransaction: record,
            );
          });
        }
        continue;
      }
      if (base == null) {
        await mark('conflict', 'The notebook identity is already used in v2.');
        continue;
      }
      // Match dates normalized by the migrated projection to the original
      // baseline, without treating cache or timestamps as user edits.
      final original = {...base, 'createdAt': current['createdAt']};
      final desired = {...local, 'createdAt': current['createdAt']};
      final merged = mergeNotebookChanges(original, desired, current);
      if (merged == null) {
        await mark('conflict', 'Concurrent changes require review.');
      } else if (_sameSnapshot(merged, current)) {
        await mark('converted');
      } else {
        await convert(() async {
          await writer.writeNotebookChange(
            before: notebook!,
            after: _stageLegacyEmbeds(
              writer,
              repository.decodeBackupStrict([merged]).single,
            ),
            onCommittedInTransaction: record,
          );
        });
      }
    }
  }

  Future<void> _replayLibrary(
    LibraryV2OperationService library,
    QueryRow row,
  ) async {
    final rawBase = row.readNullable<String>('base_json');
    final rawLocal = row.read<String>('local_json');
    final database = repository.database;
    final receipt = await database
        .customSelect(
          'SELECT library_json FROM legacy_v1_projection_cutover WHERE account_id = ?',
          variables: [Variable<String>(accountId)],
        )
        .getSingle();
    final rawServer = receipt.readNullable<String>('library_json');
    final archived = rawServer == null ? null : jsonDecode(rawServer);
    Future<void> mark(List<String> conflicts) async {
      _assertCurrent();
      await database.customStatement(
        'UPDATE legacy_v1_cutover_intents SET state = ?, reason = ? WHERE uid = ?',
        [
          conflicts.isEmpty ? 'converted' : 'conflict',
          conflicts.isEmpty ? null : conflicts.join('\n'),
          OperationEnvelope.libraryDocumentId,
        ],
      );
    }

    final notebooks = await repository.fetchNotebooks();
    if (repository.lastFetchSkippedCorruptRows) {
      throw StateError('Cannot protect folders with unreadable v2 notebooks.');
    }
    try {
      await library.replayLegacyMetadata(
        base: rawBase == null ? null : jsonDecode(rawBase),
        local: jsonDecode(rawLocal),
        cutover: archived,
        protectedFolders: notebooks.map((note) => note.folder).toSet(),
        onCommitted: mark,
      );
    } on FormatException {
      await mark([
        'Invalid legacy folder or task data. The original values were kept.',
      ]);
    } on TypeError {
      await mark([
        'Invalid legacy folder or task shape. The original values were kept.',
      ]);
    }
  }

  Notebook _stageLegacyEmbeds(
    EditorV2OperationWriter writer,
    Notebook notebook,
  ) {
    final pages = <NotePage>[];
    for (final page in notebook.pages) {
      final blocks = [...page.textBlocks];
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        if (block.deltaJson == null) {
          continue;
        }
        final delta = jsonDecode(block.deltaJson!) as List<dynamic>;
        var changed = false;
        for (final item in delta) {
          final embed = (item as Map)['insert'];
          if (embed is! Map) {
            continue;
          }
          final kind = embed.keys.single as String;
          final data = embed.values.single;
          if (data is! String) {
            throw const FormatException('Invalid legacy Quill asset.');
          }
          if (data.startsWith('asset:')) {
            continue;
          }
          final match = RegExp(r'^data:[^;]+;base64,').firstMatch(data);
          if (match == null) {
            throw const FormatException(
              'No verified bytes for legacy Quill asset.',
            );
          }
          final asset = writer.stageQuillAsset(
            documentId: notebook.uid,
            bytes: base64Decode(data.substring(match.end)),
            embedType: kind,
          );
          item['insert'] = {kind: 'asset:${asset.assetId}'};
          changed = true;
        }
        if (changed) {
          blocks[i] = block.copyWith(deltaJson: jsonEncode(delta));
        }
      }
      pages.add(page.copyWith(textBlocks: blocks));
    }
    return notebook.copyWith(pages: pages);
  }

  Future<bool> _hasPostMigrationChanges(String uid) async {
    final entries = await repository.database
        .customSelect(
          "SELECT 1 FROM operations WHERE document_id = ? "
          "AND actor_id NOT LIKE 'v1-cutover:%' LIMIT 1",
          variables: [Variable<String>(uid)],
        )
        .getSingleOrNull();
    return entries != null;
  }

  Future<List<({String uid, String reason})>> conflicts() async {
    await _createQueue();
    final rows = await repository.database
        .customSelect(
          "SELECT uid, reason FROM legacy_v1_cutover_intents WHERE state = 'conflict' ORDER BY uid",
        )
        .get();
    return [
      for (final row in rows)
        (uid: row.read<String>('uid'), reason: row.read<String>('reason')),
    ];
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
