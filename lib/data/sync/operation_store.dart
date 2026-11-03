import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../drift/notes_database.dart';
import 'operation_protocol.dart';

/// Immutable, checksummed projection of an acknowledged document state.
class StoredDocumentSnapshot {
  const StoredDocumentSnapshot({
    required this.documentId,
    required this.serverSequence,
    required this.json,
    required this.sha256,
  });

  final String documentId;
  final int serverSequence;
  final String json;
  final String sha256;
}

/// Stores operations and their SQLite projections in one Drift transaction.
///
/// Projection callbacks must write through [database]. Asset bytes should be
/// flushed and checksummed before the transaction; a transaction only commits
/// their references. Legacy snapshot writers are migrated in later stages.
class OperationStore {
  OperationStore(this.database);

  final NotesDatabase database;
  final Map<String, Future<void>> _documentTails = {};
  static const _uuid = Uuid();
  static final _checksumPattern = RegExp(r'^[a-f0-9]{64}$');

  Future<T> _perDocument<T>(
    String documentId,
    Future<T> Function() task,
  ) async {
    final previous = _documentTails[documentId];
    final done = Completer<void>();
    _documentTails[documentId] = done.future;
    try {
      if (previous != null) {
        await previous;
      }
      return await task();
    } finally {
      done.complete();
      if (identical(_documentTails[documentId], done.future)) {
        _documentTails.remove(documentId);
      }
    }
  }

  Future<Map<String, dynamic>?> _row(
    String sql,
    List<Object> args,
  ) async {
    final row = await database.customSelect(
      sql,
      variables: [
        for (final value in args)
          if (value is int)
            Variable<int>(value)
          else
            Variable<String>(value as String),
      ],
    ).getSingleOrNull();
    return row?.data;
  }

  Future<OperationEnvelope?> operation(String operationId) async {
    final row = await _row(
      'SELECT envelope_json FROM operations WHERE operation_id = ?',
      [operationId],
    );
    if (row == null) {
      return null;
    }
    return OperationEnvelope.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(row['envelope_json'] as String) as Map,
      ),
    );
  }

  /// Allocates actorSeq atomically. A rolled-back edit consumes no sequence.
  Future<OperationEnvelope> writeLocal({
    required String actorId,
    required String documentId,
    required OperationKind kind,
    required Map<String, dynamic> payload,
    required Future<void> Function(OperationEnvelope operation) apply,
    String? pageId,
    String? objectId,
    String? revertsOperationId,
    List<String> dependencies = const [],
  }) {
    return _perDocument(documentId, () async {
      return database.transaction(() async {
        final state = await _row(
          'SELECT last_seq, last_clock, last_operation_id '
          'FROM operation_actor_state WHERE actor_id = ?',
          [actorId],
        );
        final previousId = state?['last_operation_id'] as String?;
        final causalIds = <String>{
          ...dependencies,
          if (previousId != null) previousId,
        }.toList()..sort();
        var nextClock = state?['last_clock'] as int? ?? 0;
        for (final id in causalIds) {
          final dependency = await operation(id);
          if (dependency == null) {
            throw StateError('Missing causal dependency: $id');
          }
          if (dependency.logicalClock > nextClock) {
            nextClock = dependency.logicalClock;
          }
        }
        final nextSeq = (state?['last_seq'] as int? ?? 0) + 1;
        if (nextSeq > OperationEnvelope.maxSafeInteger ||
            nextClock >= OperationEnvelope.maxSafeInteger) {
          throw StateError('Actor clock exhausted.');
        }
        final next = OperationEnvelope(
          operationId: _uuid.v4(),
          actorId: actorId,
          actorSeq: nextSeq,
          logicalClock: nextClock + 1,
          documentId: documentId,
          pageId: pageId,
          objectId: objectId,
          kind: kind,
          payload: payload,
          dependencies: causalIds,
          revertsOperationId: revertsOperationId,
        );
        await _commit(next, source: 'local', apply: () => apply(next));
        return next;
      });
    });
  }

  /// An explicit envelope may be retried using its original operation ID.
  Future<bool> commitLocal(
    OperationEnvelope operation, {
    required Future<void> Function() apply,
  }) {
    return _perDocument(operation.documentId, () {
      return database.transaction(
        () => _commit(operation, source: 'local', apply: apply),
      );
    });
  }

  /// Incoming projection and server feed position commit or roll back together.
  Future<bool> applyRemote(
    OperationEnvelope operation, {
    required String checkpointScope,
    required int serverSequence,
    required Future<void> Function() apply,
  }) {
    return _perDocument(operation.documentId, () {
      return database.transaction(() async {
        final changed = await _commit(
          operation,
          source: 'remote',
          apply: apply,
        );
        await _advanceCheckpoint(checkpointScope, serverSequence);
        return changed;
      });
    });
  }

  Future<bool> _commit(
    OperationEnvelope entry, {
    required String source,
    required Future<void> Function() apply,
  }) async {
    final existing = await operation(entry.operationId);
    if (existing != null) {
      if (!const DeepCollectionEquality().equals(
        existing.toJson(),
        entry.toJson(),
      )) {
        throw StateError('Operation ID reused for different content.');
      }
      return false;
    }
    final state = await _row(
      'SELECT last_seq, last_clock, last_operation_id '
      'FROM operation_actor_state WHERE actor_id = ?',
      [entry.actorId],
    );
    final expectedSeq = (state?['last_seq'] as int? ?? 0) + 1;
    if (entry.actorSeq != expectedSeq ||
        entry.logicalClock <= (state?['last_clock'] as int? ?? 0)) {
      throw StateError('Out-of-order actor operation.');
    }
    final previous = state?['last_operation_id'] as String?;
    if (previous != null && !entry.dependencies.contains(previous)) {
      throw StateError('Actor predecessor was omitted.');
    }
    for (final id in entry.dependencies) {
      final dependency = await operation(id);
      if (dependency == null ||
          dependency.logicalClock >= entry.logicalClock) {
        throw StateError('Invalid causal dependency: $id');
      }
    }
    await _rejectDeletedTarget(entry);
    await apply();

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await database.customStatement(
      'INSERT INTO operations (operation_id, actor_id, actor_seq, '
      'document_id, page_id, object_id, kind, envelope_json, '
      'logical_clock, schema_version, source, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        entry.operationId,
        entry.actorId,
        entry.actorSeq,
        entry.documentId,
        entry.pageId,
        entry.objectId,
        entry.kind.wireName,
        jsonEncode(entry.toJson()),
        entry.logicalClock,
        entry.schemaVersion,
        source,
        now,
      ],
    );
    await database.customStatement(
      'INSERT INTO operation_actor_state '
      '(actor_id, last_seq, last_clock, last_operation_id) '
      'VALUES (?, ?, ?, ?) ON CONFLICT(actor_id) DO UPDATE SET '
      'last_seq = excluded.last_seq, last_clock = excluded.last_clock, '
      'last_operation_id = excluded.last_operation_id',
      [
        entry.actorId,
        entry.actorSeq,
        entry.logicalClock,
        entry.operationId,
      ],
    );
    if (source == 'local') {
      await database.customStatement(
        'INSERT INTO operation_outbox (operation_id, queued_at) '
        'VALUES (?, ?)',
        [entry.operationId, now],
      );
    }
    await _writeTombstone(entry);
    return true;
  }

  Future<void> _rejectDeletedTarget(OperationEnvelope entry) async {
    final document = entry.documentId;
    if (await isTombstoned(document, 'document', document)) {
      throw StateError('Document has been deleted.');
    }
    if (entry.kind.target == OperationTarget.object &&
        await isTombstoned(document, 'page', entry.pageId!)) {
      throw StateError('Page has been deleted.');
    }
    final target = switch (entry.kind.target) {
      OperationTarget.document => (kind: 'document', id: document),
      OperationTarget.page => (kind: 'page', id: entry.objectId!),
      OperationTarget.object => (kind: 'object', id: entry.objectId!),
      OperationTarget.folder => (kind: 'folder', id: entry.objectId!),
    };
    if (await isTombstoned(document, target.kind, target.id)) {
      throw StateError('Deleted identity cannot be reused.');
    }
  }

  Future<bool> isTombstoned(
    String documentId,
    String targetKind,
    String objectId,
  ) async {
    return await _row(
      'SELECT operation_id FROM object_tombstones '
      'WHERE document_id = ? AND target_kind = ? AND object_id = ?',
      [documentId, targetKind, objectId],
    ) != null;
  }

  Future<void> _writeTombstone(OperationEnvelope entry) async {
    final targetKind = switch (entry.kind) {
      OperationKind.documentDelete => 'document',
      OperationKind.pageDelete => 'page',
      OperationKind.objectDelete => 'object',
      OperationKind.folderDelete => 'folder',
      _ => null,
    };
    if (targetKind == null) {
      return;
    }
    await database.customStatement(
      'INSERT INTO object_tombstones '
      '(document_id, target_kind, object_id, operation_id) '
      'VALUES (?, ?, ?, ?)',
      [
        entry.documentId,
        targetKind,
        targetKind == 'document' ? entry.documentId : entry.objectId!,
        entry.operationId,
      ],
    );
  }

  /// A retry never deletes an unacknowledged operation.
  Future<List<OperationEnvelope>> pending({
    String? documentId,
    int limit = 128,
    bool includeDeferred = false,
  }) async {
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit');
    }
    final filter = documentId == null ? '' : 'AND o.document_id = ? ';
    // Never transmit a later actor sequence while its predecessor is
    // delayed. A rebase needs *all* unacknowledged edits, including retries.
    final ready = includeDeferred
        ? ''
        : 'AND x.retry_after <= ? AND NOT EXISTS ('
              'SELECT 1 FROM operation_outbox earlier '
              'JOIN operations predecessor '
              'ON predecessor.operation_id = earlier.operation_id '
              'WHERE predecessor.actor_id = o.actor_id '
              'AND predecessor.actor_seq < o.actor_seq '
              'AND earlier.retry_after > ?) ';
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rows = await database.customSelect(
      'SELECT o.envelope_json FROM operation_outbox x '
      'JOIN operations o ON o.operation_id = x.operation_id '
      'WHERE 1 = 1 $ready$filter'
      'ORDER BY o.actor_id, o.actor_seq LIMIT ?',
      variables: [
        if (!includeDeferred) ...[Variable<int>(now), Variable<int>(now)],
        if (documentId != null) Variable<String>(documentId),
        Variable<int>(limit),
      ],
    ).get();
    return [
      for (final row in rows)
        OperationEnvelope.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(row.read<String>('envelope_json')) as Map,
          ),
        ),
    ];
  }

  Future<void> scheduleRetry(
    String operationId, {
    required Duration delay,
  }) async {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay');
    }
    final at = DateTime.now().toUtc().add(delay).millisecondsSinceEpoch;
    await database.customStatement(
      'UPDATE operation_outbox SET attempts = attempts + 1, '
      'retry_after = ? WHERE operation_id = ?',
      [at, operationId],
    );
  }

  /// ACK and outbox deletion are atomic and idempotent.
  Future<void> acknowledge(
    String operationId, {
    required int serverSequence,
  }) async {
    if (serverSequence <= 0) {
      throw ArgumentError.value(serverSequence, 'serverSequence');
    }
    await database.transaction(() async {
      final existing = await _row(
        'SELECT server_sequence FROM operation_ack WHERE operation_id = ?',
        [operationId],
      );
      if (existing != null) {
        if (existing['server_sequence'] != serverSequence) {
          throw StateError('Conflicting server acknowledgement.');
        }
        return;
      }
      if (await operation(operationId) == null) {
        throw StateError('Cannot acknowledge an unknown operation.');
      }
      await database.customStatement(
        'INSERT INTO operation_ack '
        '(operation_id, server_sequence, acknowledged_at) '
        'VALUES (?, ?, ?)',
        [
          operationId,
          serverSequence,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
      await database.customStatement(
        'DELETE FROM operation_outbox WHERE operation_id = ?',
        [operationId],
      );
    });
  }

  Future<int> checkpoint(String scope) async {
    final row = await _row(
      'SELECT server_sequence FROM sync_checkpoints WHERE scope = ?',
      [scope],
    );
    return row?['server_sequence'] as int? ?? 0;
  }

  /// Persist a contiguous feed cursor. Replayed rows are idempotent.
  ///
  /// The caller must only advance through operations committed locally.
  Future<void> advanceCheckpoint(String scope, int sequence) {
    return database.transaction(() => _advanceCheckpoint(scope, sequence));
  }

  Future<void> _advanceCheckpoint(String scope, int sequence) async {
    if (scope.isEmpty || sequence < 0) {
      throw ArgumentError('Invalid sync checkpoint.');
    }
    final current = await checkpoint(scope);
    if (sequence < current) {
      throw StateError('Sync cursor cannot move backwards.');
    }
    await database.customStatement(
      'INSERT INTO sync_checkpoints (scope, server_sequence, updated_at) '
      'VALUES (?, ?, ?) ON CONFLICT(scope) DO UPDATE SET '
      'server_sequence = excluded.server_sequence, '
      'updated_at = excluded.updated_at',
      [
        scope,
        sequence,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  /// Snapshots cannot capture local operations still awaiting server ACK.
  Future<StoredDocumentSnapshot> saveSnapshot({
    required String documentId,
    required int serverSequence,
    required String snapshotJson,
  }) async {
    if (serverSequence < 0) {
      throw ArgumentError.value(serverSequence, 'serverSequence');
    }
    jsonDecode(snapshotJson);
    final checksum = sha256.convert(utf8.encode(snapshotJson)).toString();
    return database.transaction(() async {
      final pending = await _row(
        'SELECT x.operation_id FROM operation_outbox x '
        'JOIN operations o ON o.operation_id = x.operation_id '
        'WHERE o.document_id = ? LIMIT 1',
        [documentId],
      );
      if (pending != null) {
        throw StateError('Cannot snapshot unacknowledged edits.');
      }
      final known = await _row(
        'SELECT checksum_sha256 FROM document_snapshots '
        'WHERE document_id = ? AND server_sequence = ?',
        [documentId, serverSequence],
      );
      if (known != null && known['checksum_sha256'] != checksum) {
        throw StateError('Immutable snapshot checksum mismatch.');
      }
      if (known == null) {
        await database.customStatement(
          'INSERT INTO document_snapshots '
          '(document_id, server_sequence, snapshot_json, '
          'checksum_sha256, created_at) VALUES (?, ?, ?, ?, ?)',
          [
            documentId,
            serverSequence,
            snapshotJson,
            checksum,
            DateTime.now().toUtc().millisecondsSinceEpoch,
          ],
        );
      }
      return StoredDocumentSnapshot(
        documentId: documentId,
        serverSequence: serverSequence,
        json: snapshotJson,
        sha256: checksum,
      );
    });
  }

  Future<StoredDocumentSnapshot?> latestSnapshot(
    String documentId,
  ) async {
    final row = await _row(
      'SELECT document_id, server_sequence, snapshot_json, checksum_sha256 '
      'FROM document_snapshots WHERE document_id = ? '
      'ORDER BY server_sequence DESC LIMIT 1',
      [documentId],
    );
    if (row == null) {
      return null;
    }
    final json = row['snapshot_json'] as String;
    final checksum = sha256.convert(utf8.encode(json)).toString();
    if (checksum != row['checksum_sha256']) {
      throw StateError('Corrupt document snapshot.');
    }
    return StoredDocumentSnapshot(
      documentId: documentId,
      serverSequence: row['server_sequence'] as int,
      json: json,
      sha256: checksum,
    );
  }

  /// Records a durable asset reference; file GC is checkpoint-aware and later.
  Future<void> attachAssetReference({
    required String documentId,
    required String objectId,
    required String assetId,
    required String storagePath,
    required String checksumSha256,
    required int byteLength,
  }) async {
    if (documentId.isEmpty || objectId.isEmpty || assetId.isEmpty ||
        storagePath.isEmpty || byteLength <= 0 ||
        !_checksumPattern.hasMatch(checksumSha256)) {
      throw ArgumentError('Invalid asset reference.');
    }
    final existing = await _row(
      'SELECT storage_path, checksum_sha256, byte_length '
      'FROM asset_references WHERE document_id = ? AND object_id = ? '
      'AND asset_id = ?',
      [documentId, objectId, assetId],
    );
    if (existing != null) {
      if (existing['storage_path'] != storagePath ||
          existing['checksum_sha256'] != checksumSha256 ||
          existing['byte_length'] != byteLength) {
        throw StateError('Asset identity reused with different content.');
      }
      return;
    }
    await database.customStatement(
      'INSERT INTO asset_references '
      '(document_id, object_id, asset_id, storage_path, '
      'checksum_sha256, byte_length) VALUES (?, ?, ?, ?, ?, ?)',
      [
        documentId,
        objectId,
        assetId,
        storagePath,
        checksumSha256,
        byteLength,
      ],
    );
  }
}
