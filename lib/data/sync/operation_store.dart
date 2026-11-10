import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../drift/notes_database.dart';
import 'operation_protocol.dart';
import 'operation_text_sequence.dart';

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

/// A single object-level intent within one atomic editor gesture.
class LocalOperationDraft {
  const LocalOperationDraft({
    required this.kind,
    required this.payload,
    this.pageId,
    this.objectId,
    this.revertsOperationId,
    this.dependencies = const [],
  });

  final OperationKind kind;
  final Map<String, dynamic> payload;
  final String? pageId;
  final String? objectId;
  final String? revertsOperationId;
  final List<String> dependencies;
}

/// Stores operations and their SQLite projections in one Drift transaction.
///
/// Projection callbacks must write through [database]. Asset bytes should be
/// flushed and checksummed before the transaction; a transaction only commits
/// their references. Legacy snapshot writers are migrated in later stages.
class OperationStore {
  OperationStore(this.database, {this.checkpointScope});

  final NotesDatabase database;
  /// The account feed checkpoint used for safe compact causal frontiers.
  final String? checkpointScope;
  final Map<String, Future<void>> _documentTails = {};
  String _remoteActorPrefix(String documentId) =>
      'remote-actor:${jsonEncode([checkpointScope, documentId])}:';

  String _remoteActorScope(String documentId, String actorId) =>
      '${_remoteActorPrefix(documentId)}$actorId';

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

  Future<Map<String, dynamic>?> _row(String sql, List<Object> args) async {
    final row = await database
        .customSelect(
          sql,
          variables: [
            for (final value in args)
              if (value is int)
                Variable<int>(value)
              else
                Variable<String>(value as String),
          ],
        )
        .getSingleOrNull();
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

  /// Rebuilds the text CRDT from immutable, committed operations.
  ///
  /// No tentative operation or ACK is required for recovery. Call inside the
  /// same SQLite transaction as a new text projection; the caller applies the
  /// new envelope to this result before it is inserted into the journal.
  Future<Map<String, dynamic>> textAtoms({
    required String documentId,
    required String pageId,
    required String objectId,
  }) async {
    if (documentId.isEmpty || pageId.isEmpty || objectId.isEmpty) {
      throw ArgumentError('Text CRDT lookup needs complete identity.');
    }
    final rows = await database
        .customSelect(
          'SELECT envelope_json FROM operations '
          // Object IDs are unique throughout a notebook. A v2 object.move
          // changes its page, not its CRDT identity or earlier atom history.
          'WHERE document_id = ? AND object_id = ? '
          "AND kind IN ('text.insert', 'text.delete', 'text.format') "
          'ORDER BY rowid',
          variables: [Variable<String>(documentId), Variable<String>(objectId)],
        )
        .get();
    // Replay is intentionally bounded until verified text checkpoints exist.
    // Refuse to truncate history or silently discard causally required atoms.
    if (rows.length > 50000) {
      throw StateError('Text operation history requires a checkpoint.');
    }
    var atoms = <String, dynamic>{};
    for (final row in rows) {
      final json = jsonDecode(row.read<String>('envelope_json'));
      if (json is! Map) {
        throw const FormatException('Corrupt text operation envelope.');
      }
      final operation = OperationEnvelope.fromJson(
        Map<String, dynamic>.from(json),
      );
      atoms = OperationTextSequence.apply(atoms, operation);
    }
    return atoms;
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
    return _perDocument(
      documentId,
      () => database.transaction(
        () => _writeLocalInTransaction(
          actorId: actorId,
          documentId: documentId,
          kind: kind,
          payload: payload,
          apply: apply,
          pageId: pageId,
          objectId: objectId,
          revertsOperationId: revertsOperationId,
          dependencies: dependencies,
        ),
      ),
    );
  }

  /// Commits all object changes of a gesture in the same SQLite transaction.
  ///
  /// The projection must write through [database]. On failure, no counter,
  /// projection row or outbox item from the gesture may survive.
  /// The optional checkpoint callback runs inside this transaction, after all
  /// intents. It must only write local metadata and must not mutate UI or do I/O.
  Future<List<OperationEnvelope>> writeLocalBatch({
    required String actorId,
    required String documentId,
    required List<LocalOperationDraft> operations,
    required Future<void> Function(OperationEnvelope operation) apply,
    Future<void> Function(List<OperationEnvelope>)? onCommittedInTransaction,
  }) {
    if (operations.isEmpty && onCommittedInTransaction == null) {
      throw ArgumentError.value(operations, 'operations', 'Empty gesture.');
    }
    return _perDocument(documentId, () {
      return database.transaction(() async {
        final committed = <OperationEnvelope>[];
        for (final draft in operations) {
          committed.add(
            await _writeLocalInTransaction(
              actorId: actorId,
              documentId: documentId,
              kind: draft.kind,
              payload: draft.payload,
              pageId: draft.pageId,
              objectId: draft.objectId,
              revertsOperationId: draft.revertsOperationId,
              dependencies: draft.dependencies,
              apply: apply,
            ),
          );
        }
        await onCommittedInTransaction?.call(
          List<OperationEnvelope>.unmodifiable(committed),
        );
        return committed;
      });
    });
  }

  Future<OperationEnvelope> _writeLocalInTransaction({
    required String actorId,
    required String documentId,
    required OperationKind kind,
    required Map<String, dynamic> payload,
    required Future<void> Function(OperationEnvelope operation) apply,
    String? pageId,
    String? objectId,
    String? revertsOperationId,
    List<String> dependencies = const [],
  }) async {
    final state = await _row(
      'SELECT last_seq, last_clock, last_operation_id '
      'FROM operation_actor_state WHERE actor_id = ?',
      [actorId],
    );
    final previousId = state?['last_operation_id'] as String?;
    // A new local intent observes the durable remote actor frontier.
    // This must be read inside the same transaction as actorSeq.
    final observed = await database
        .customSelect(
          'SELECT actor.last_operation_id, latest.source, '
          'ack.server_sequence AS ack_cursor, '
          'remote.server_sequence AS remote_cursor '
          'FROM operation_actor_state actor '
          'JOIN operations latest '
          'ON latest.operation_id = actor.last_operation_id '
          'LEFT JOIN operation_ack ack '
          'ON ack.operation_id = actor.last_operation_id '
          'LEFT JOIN sync_checkpoints remote '
          "ON remote.scope = ? || actor.actor_id "
          'WHERE actor.actor_id != ? AND latest.document_id = ? '
          'ORDER BY actor.actor_id',
          variables: [
            Variable<String>(_remoteActorPrefix(documentId)),
            Variable<String>(actorId),
            Variable<String>(documentId),
          ],
        )
        .get();
    final observedIds = <String>{
      for (final row in observed) row.read<String>('last_operation_id'),
    };
    final compactCursor = checkpointScope == null
        ? 0
        : await checkpoint(checkpointScope!);
    final coveredByCursor = <String>{};
    for (final row in observed) {
      final receipt = row.read<String>('source') == 'local'
          ? row.readNullable<int>('ack_cursor')
          : row.readNullable<int>('remote_cursor');
      if (receipt != null && receipt <= compactCursor) {
        coveredByCursor.add(row.read<String>('last_operation_id'));
      }
    }
    final requiredIds = <String>{
      ...dependencies,
      if (revertsOperationId != null) revertsOperationId,
      if (previousId != null) previousId,
    };
    final available = <String, OperationEnvelope>{};
    var nextClock = state?['last_clock'] as int? ?? 0;
    for (final id in {...observedIds, ...requiredIds}) {
      final dependency = await operation(id);
      if (dependency == null || dependency.documentId != documentId) {
        throw StateError('Invalid document dependency: $id');
      }
      available[id] = dependency;
      if (dependency.logicalClock > nextClock) {
        nextClock = dependency.logicalClock;
      }
    }
    // A frontier already required by another observed operation is
    // causally implied. Never drop explicit, undo or actor predecessors.
    final coveredIds = <String>{
      for (final op in available.values)
        for (final id in op.dependencies)
          if (observedIds.contains(id)) id,
    };
    final causalIds = <String>{
      ...requiredIds,
      for (final id in observedIds)
        if (!coveredIds.contains(id) && !coveredByCursor.contains(id)) id,
    }.toList()..sort();
    if (causalIds.length * 39 > OperationEnvelope.maxDependencyBytes) {
      throw StateError('Uncovered causal frontier exceeds wire budget.');
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
      causalCursor: compactCursor == 0 ? null : compactCursor,
    );
    await _commit(next, source: 'local', apply: () => apply(next));
    return next;
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
    String? checkpointScope,
    required int serverSequence,
    int? coveredCursor,
    required Future<void> Function() apply,
  }) {
    return _perDocument(operation.documentId, () {
      return database.transaction(() async {
        if (operation.causalCursor != null &&
            operation.causalCursor! >= serverSequence) {
          throw StateError('Compact cursor cannot cover its own operation.');
        }
        final changed = await _commit(
          operation,
          source: 'remote',
          apply: apply,
          coveredCursor: coveredCursor ??
              (checkpointScope == null ? 0 : await checkpoint(checkpointScope)),
        );
        final actorScope = _remoteActorScope(operation.documentId, operation.actorId);
        if (serverSequence > await checkpoint(actorScope)) {
          await _advanceCheckpoint(actorScope, serverSequence);
        }
        if (checkpointScope != null) {
          await _advanceCheckpoint(checkpointScope, serverSequence);
        }
        return changed;
      });
    });
  }

  Future<bool> _commit(
    OperationEnvelope entry, {
    required String source,
    required Future<void> Function() apply,
    int? coveredCursor,
  }) async {
    if (entry.causalCursor != null) {
      final appliedCursor = coveredCursor ??
          (checkpointScope == null ? 0 : await checkpoint(checkpointScope!));
      if (appliedCursor < entry.causalCursor!) {
        throw StateError('Compact causal frontier has not been applied.');
      }
    }
    if (source == 'local') {
      entry.validateForV2Projection();
    }
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
      final previousReceipt = await _row(
        'SELECT o.source, ack.server_sequence AS ack_cursor, '
        'remote.server_sequence AS remote_cursor '
        'FROM operations o LEFT JOIN operation_ack ack '
        'ON ack.operation_id = o.operation_id '
        'LEFT JOIN sync_checkpoints remote ON remote.scope = ? '
        'WHERE o.operation_id = ?',
        [_remoteActorScope(entry.documentId, entry.actorId), previous],
      );
      final covered = previousReceipt?['source'] == 'local'
          ? previousReceipt?['ack_cursor'] as int?
          : previousReceipt?['remote_cursor'] as int?;
      if (covered == null ||
          entry.causalCursor == null ||
          covered > entry.causalCursor!) {
        throw StateError('Actor predecessor was omitted.');
      }
    }
    for (final id in entry.dependencies) {
      final dependency = await operation(id);
      if (dependency == null || dependency.logicalClock >= entry.logicalClock) {
        throw StateError('Invalid causal dependency: $id');
      }
      if (dependency.documentId != entry.documentId) {
        throw StateError('Cross-document causal dependency: $id');
      }
    }
    final deleted = await _isDeletedTarget(entry);
    if (deleted && source == 'local') {
      throw StateError('Deleted identity cannot be reused.');
    }
    // The server may accept an old concurrent edit as an ignored no-op.
    // Record its actor sequence and cursor without resurrecting the target.
    if (!deleted) {
      await apply();
    }

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
      [entry.actorId, entry.actorSeq, entry.logicalClock, entry.operationId],
    );
    if (source == 'local') {
      await database.customStatement(
        'INSERT INTO operation_outbox (operation_id, queued_at) '
        'VALUES (?, ?)',
        [entry.operationId, now],
      );
    }
    if (!deleted) {
      await _writeTombstone(entry);
    }
    return true;
  }

  Future<bool> _isDeletedTarget(OperationEnvelope entry) async {
    final document = entry.documentId;
    if (await isTombstoned(document, 'document', document)) {
      return true;
    }
    if (entry.kind.target == OperationTarget.object &&
        await isTombstoned(document, 'page', entry.pageId!)) {
      return true;
    }
    final target = switch (entry.kind.target) {
      OperationTarget.document => (kind: 'document', id: document),
      OperationTarget.page => (kind: 'page', id: entry.objectId!),
      OperationTarget.object => (kind: 'object', id: entry.objectId!),
      OperationTarget.folder => (kind: 'folder', id: entry.objectId!),
      OperationTarget.task => (kind: 'task', id: entry.objectId!),
    };
    return isTombstoned(
      document,
      target.kind,
      target.id,
      pageId: target.kind == 'object' ? entry.pageId : null,
    );
  }

  Future<bool> isTombstoned(
    String documentId,
    String targetKind,
    String objectId, {
    String? pageId,
  }) async {
    if (targetKind == 'object' && (pageId == null || pageId.isEmpty)) {
      throw ArgumentError('Object tombstones require a page ID.');
    }
    return await _row(
          'SELECT operation_id FROM object_tombstones '
          'WHERE document_id = ? AND target_kind = ? '
          'AND page_id = ? AND object_id = ?',
          [
            documentId,
            targetKind,
            targetKind == 'object' ? pageId! : '',
            objectId,
          ],
        ) !=
        null;
  }

  /// Object identities are unique within a document, even after a move.
  /// A late remote event may refer to the page where an object used to live.
  Future<bool> wasObjectDeleted({
    required String documentId,
    required String objectId,
  }) async {
    if (documentId.isEmpty || objectId.isEmpty) {
      throw ArgumentError('Object tombstone lookup needs complete identity.');
    }
    return await _row(
          'SELECT operation_id FROM object_tombstones '
          "WHERE document_id = ? AND target_kind = 'object' "
          'AND object_id = ? LIMIT 1',
          [documentId, objectId],
        ) !=
        null;
  }

  Future<void> _writeTombstone(OperationEnvelope entry) async {
    final targetKind = switch (entry.kind) {
      OperationKind.documentDelete => 'document',
      OperationKind.pageDelete => 'page',
      OperationKind.objectDelete => 'object',
      OperationKind.folderDelete => 'folder',
      OperationKind.taskDelete => 'task',
      _ => null,
    };
    if (targetKind == null) {
      return;
    }
    await database.customStatement(
      'INSERT INTO object_tombstones '
      '(document_id, target_kind, page_id, object_id, operation_id) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        entry.documentId,
        targetKind,
        targetKind == 'object' ? entry.pageId! : '',
        targetKind == 'document' ? entry.documentId : entry.objectId!,
        entry.operationId,
      ],
    );
  }

  /// A retry never deletes an unacknowledged operation.
  Future<List<OperationEnvelope>> pending({
    String? documentId,
    int limit = 128,
    int offset = 0,
    bool includeDeferred = false,
  }) async {
    if (limit < 1 || limit > 1000 || offset < 0) {
      throw ArgumentError('Invalid outbox pagination.');
    }
    final filter = documentId == null ? '' : 'AND o.document_id = ? ';
    // Never transmit a later actor sequence while its predecessor is
    // delayed. A rebase needs *all* unacknowledged edits, including retries.
    final ready = includeDeferred
        ? ''
        : "AND x.status = 'queued' "
              'AND x.retry_after <= ? AND NOT EXISTS ('
              'SELECT 1 FROM operation_outbox earlier '
              'JOIN operations predecessor '
              'ON predecessor.operation_id = earlier.operation_id '
              'WHERE predecessor.actor_id = o.actor_id '
              'AND predecessor.actor_seq < o.actor_seq '
              "AND (earlier.status = 'blocked' "
              'OR earlier.retry_after > ?)) ';
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rows = await database
        .customSelect(
          'SELECT o.envelope_json FROM operation_outbox x '
          'JOIN operations o ON o.operation_id = x.operation_id '
          'WHERE 1 = 1 $ready$filter'
          'ORDER BY o.actor_id, o.actor_seq LIMIT ? OFFSET ?',
          variables: [
            if (!includeDeferred) ...[Variable<int>(now), Variable<int>(now)],
            if (documentId != null) Variable<String>(documentId),
            Variable<int>(limit),
            Variable<int>(offset),
          ],
        )
        .get();
    return [
      for (final row in rows)
        OperationEnvelope.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(row.read<String>('envelope_json')) as Map,
          ),
        ),
    ];
  }

  /// Local journal entries remain local after the server ACK removes outbox.
  /// This prevents a replayed echo from repainting the editor on reconnect.
  Future<bool> isLocalOperation(String operationId) async {
    final row = await _row(
      'SELECT source FROM operations WHERE operation_id = ?',
      [operationId],
    );
    return row?['source'] == 'local';
  }

  /// Distinguishes a locally queued echo from an ordinary remote replay.
  Future<bool> isPending(String operationId) async {
    return await _row(
          'SELECT operation_id FROM operation_outbox WHERE operation_id = ?',
          [operationId],
        ) !=
        null;
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
      "retry_after = ? WHERE operation_id = ? AND status = 'queued'",
      [at, operationId],
    );
  }

  /// Retains an operation the server has permanently rejected.
  /// Later actor sequences remain blocked, but other actors can progress.
  Future<void> markBlocked(String operationId, String reason) async {
    if (reason.isEmpty) {
      throw ArgumentError('A blocked operation needs a reason.');
    }
    await database.transaction(() async {
      if (!await isPending(operationId)) {
        throw StateError('Cannot block an unknown operation.');
      }
      await database.customStatement(
        "UPDATE operation_outbox SET status = 'blocked', last_error = ? "
        'WHERE operation_id = ?',
        [reason, operationId],
      );
    });
  }

  Future<String?> blockedReason(String operationId) async {
    final row = await _row(
      "SELECT last_error FROM operation_outbox WHERE operation_id = ? "
      "AND status = 'blocked'",
      [operationId],
    );
    return row?['last_error'] as String?;
  }

  /// ACK and outbox deletion are atomic and idempotent.
  Future<void> acknowledge(String operationId, {required int serverSequence}) =>
      acknowledgeBatch({operationId: serverSequence});

  /// Accept a full server receipt batch or retain every pending intent.
  ///
  /// One invalid receipt, a reused cursor or an interrupted write rolls back
  /// the entire batch. Already-acknowledged retries must keep their original
  /// server cursor. A receipt cannot acknowledge a remote-only operation.
  Future<void> acknowledgeBatch(Map<String, int> cursors) async {
    if (cursors.isEmpty ||
        cursors.keys.any((id) => id.isEmpty) ||
        cursors.values.any(
          (cursor) => cursor <= 0 || cursor > OperationEnvelope.maxSafeInteger,
        ) ||
        cursors.values.toSet().length != cursors.length) {
      throw ArgumentError('Invalid operation acknowledgement batch.');
    }
    await database.transaction(() async {
      final actorReceipts = <String, List<(int, int)>>{};
      for (final entry in cursors.entries) {
        final id = entry.key;
        final sequence = entry.value;
        final local = await _row(
          'SELECT source, actor_id, actor_seq '
          'FROM operations WHERE operation_id = ?',
          [id],
        );
        if (local == null || local['source'] != 'local') {
          throw StateError('Cannot acknowledge a nonlocal operation.');
        }
        final actor = local['actor_id'] as String;
        final actorSequence = local['actor_seq'] as int;
        actorReceipts.putIfAbsent(actor, () => <(int, int)>[]).add((
          actorSequence,
          sequence,
        ));
        // Earlier ACK batches must not reuse a global cursor or reverse the
        // actor's causal order. Compare against durable receipts after restart.
        final reused = await _row(
          'SELECT operation_id FROM operation_ack '
          'WHERE server_sequence = ? AND operation_id != ? LIMIT 1',
          [sequence, id],
        );
        if (reused != null) {
          throw StateError('Server cursor belongs to another operation.');
        }
        final older = await _row(
          'SELECT MAX(a.server_sequence) AS cursor '
          'FROM operation_ack a INNER JOIN operations o '
          'ON o.operation_id = a.operation_id '
          'WHERE o.actor_id = ? AND o.actor_seq < ?',
          [actor, actorSequence],
        );
        final olderCursor = older?['cursor'] as int?;
        if (olderCursor != null && olderCursor >= sequence) {
          throw StateError('Non-monotonic historical actor ACK.');
        }
        final newer = await _row(
          'SELECT MIN(a.server_sequence) AS cursor '
          'FROM operation_ack a INNER JOIN operations o '
          'ON o.operation_id = a.operation_id '
          'WHERE o.actor_id = ? AND o.actor_seq > ?',
          [actor, actorSequence],
        );
        final newerCursor = newer?['cursor'] as int?;
        if (newerCursor != null && newerCursor <= sequence) {
          throw StateError('Non-monotonic historical actor ACK.');
        }
        final existing = await _row(
          'SELECT server_sequence FROM operation_ack WHERE operation_id = ?',
          [id],
        );
        if (existing != null) {
          if (existing['server_sequence'] != sequence) {
            throw StateError('Conflicting server acknowledgement.');
          }
          continue;
        }
        if (!await isPending(id)) {
          throw StateError('Cannot acknowledge an operation outside outbox.');
        }
        await database.customStatement(
          'INSERT INTO operation_ack '
          '(operation_id, server_sequence, acknowledged_at) '
          'VALUES (?, ?, ?)',
          [id, sequence, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        await database.customStatement(
          'DELETE FROM operation_outbox WHERE operation_id = ?',
          [id],
        );
      }
      for (final actor in actorReceipts.values) {
        actor.sort((left, right) => left.$1.compareTo(right.$1));
        for (var index = 1; index < actor.length; index++) {
          if (actor[index].$2 <= actor[index - 1].$2) {
            throw StateError('Non-monotonic actor acknowledgement.');
          }
        }
      }
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
    if (scope.isEmpty ||
        sequence < 0 ||
        sequence > OperationEnvelope.maxSafeInteger) {
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
      [scope, sequence, DateTime.now().toUtc().millisecondsSinceEpoch],
    );
  }

  /// Snapshots cannot capture local operations still awaiting server ACK.
  Future<StoredDocumentSnapshot> saveSnapshot({
    required String documentId,
    required int serverSequence,
    required String snapshotJson,
  }) async {
    if (serverSequence < 0 ||
        serverSequence > OperationEnvelope.maxSafeInteger) {
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
      final acknowledged = await _row(
        'SELECT MAX(a.server_sequence) AS latest FROM operation_ack a '
        'JOIN operations o ON o.operation_id = a.operation_id '
        'WHERE o.document_id = ?',
        [documentId],
      );
      if (serverSequence < (acknowledged?['latest'] as int? ?? 0)) {
        throw StateError('Snapshot predates an acknowledged operation.');
      }
      final mostRecent = await _row(
        'SELECT MAX(server_sequence) AS latest FROM document_snapshots '
        'WHERE document_id = ?',
        [documentId],
      );
      if (serverSequence < (mostRecent?['latest'] as int? ?? 0)) {
        throw StateError('Snapshot checkpoint cannot move backwards.');
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

  Future<StoredDocumentSnapshot?> latestSnapshot(String documentId) async {
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
    required String pageId,
    required String objectId,
    required String assetId,
    required String storagePath,
    required String checksumSha256,
    required int byteLength,
  }) async {
    if (documentId.isEmpty ||
        pageId.isEmpty ||
        objectId.isEmpty ||
        assetId.isEmpty ||
        storagePath.isEmpty ||
        byteLength <= 0 ||
        !_checksumPattern.hasMatch(checksumSha256)) {
      throw ArgumentError('Invalid asset reference.');
    }
    // Legacy rows use a plain object ID. New references include the page
    // in an opaque key, without rewriting existing unverified asset links.
    final scopedObjectId = 'page:${jsonEncode([pageId, objectId])}';
    final existing = await _row(
      'SELECT storage_path, checksum_sha256, byte_length '
      'FROM asset_references WHERE document_id = ? AND object_id = ? '
      'AND asset_id = ?',
      [documentId, scopedObjectId, assetId],
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
        scopedObjectId,
        assetId,
        storagePath,
        checksumSha256,
        byteLength,
      ],
    );
  }
}
