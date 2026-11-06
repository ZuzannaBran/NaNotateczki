import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';

import 'editor_history_checkpoint.dart';
import 'operation_store.dart';

/// Scoped recovery metadata. Call save from the gesture's transaction callback.
/// History failure then rolls back the projection, actor state and outbox too.
class EditorHistoryStore {
  EditorHistoryStore(this.operations);
  final OperationStore operations;

  Future<String?> _head(String documentId) async {
    final row = await operations.database
        .customSelect(
          'SELECT operation_id FROM operations WHERE document_id = ? ORDER BY rowid DESC LIMIT 1',
          variables: [Variable<String>(documentId)],
        )
        .getSingleOrNull();
    return row?.read<String>('operation_id');
  }

  Future<void> _validate(EditorHistoryCheckpoint checkpoint) async {
    final owner = await operations.database
        .customSelect(
          "SELECT operation_id FROM operations WHERE document_id = ? AND actor_id = ? AND source = 'local' LIMIT 1",
          variables: [
            Variable<String>(checkpoint.documentId),
            Variable<String>(checkpoint.ownerId),
          ],
        )
        .getSingleOrNull();
    if (owner == null) {
      throw StateError(
        'History owner has no local operations in this document.',
      );
    }
    for (final id in {
      ...checkpoint.undo.map((entry) => entry.operationId),
      ...checkpoint.redo.map((entry) => entry.operationId),
    }) {
      final row = await operations.database
          .customSelect(
            'SELECT actor_id, document_id, source FROM operations WHERE operation_id = ?',
            variables: [Variable<String>(id)],
          )
          .getSingleOrNull();
      if (row == null ||
          row.read<String>('document_id') != checkpoint.documentId ||
          row.read<String>('actor_id') != checkpoint.ownerId ||
          row.read<String>('source') != 'local') {
        throw StateError(
          'History must reference local operations of its owner and document.',
        );
      }
    }
    if (await operations.isTombstoned(
      checkpoint.documentId,
      'document',
      checkpoint.documentId,
    )) {
      throw StateError('A deleted document has no recoverable editor history.');
    }
  }

  Future<void> save(EditorHistoryCheckpoint checkpoint) async {
    final json = checkpoint.encode();
    final digest = crypto.sha256.convert(utf8.encode(json)).toString();
    await operations.database.transaction(() async {
      if (await _head(checkpoint.documentId) != checkpoint.headOperationId) {
        throw StateError(
          'History checkpoint does not match the committed document head.',
        );
      }
      await _validate(checkpoint);
      await operations.database.customStatement(
        'INSERT INTO editor_history (document_id, owner_id, head_operation_id, payload_json, checksum_sha256) '
        'VALUES (?, ?, ?, ?, ?) ON CONFLICT(document_id, owner_id) DO UPDATE SET '
        'head_operation_id = excluded.head_operation_id, payload_json = excluded.payload_json, '
        'checksum_sha256 = excluded.checksum_sha256',
        [
          checkpoint.documentId,
          checkpoint.ownerId,
          checkpoint.headOperationId,
          json,
          digest,
        ],
      );
    });
  }

  /// A newer local or remote operation invalidates an older history boundary.
  /// Corruption is reported; no document rows, operations or checkpoints change.
  Future<EditorHistoryCheckpoint?> load({
    required String documentId,
    required String ownerId,
  }) => operations.database.transaction(() async {
    final row = await operations.database
        .customSelect(
          'SELECT head_operation_id, payload_json, checksum_sha256 FROM editor_history '
          'WHERE document_id = ? AND owner_id = ?',
          variables: [Variable<String>(documentId), Variable<String>(ownerId)],
        )
        .getSingleOrNull();
    if (row == null ||
        await _head(documentId) != row.read<String>('head_operation_id')) {
      return null;
    }
    final json = row.read<String>('payload_json');
    final bytes = utf8.encode(json);
    if (bytes.length > EditorHistoryCheckpoint.maximumBytes ||
        crypto.sha256.convert(bytes).toString() !=
            row.read<String>('checksum_sha256')) {
      throw const FormatException('Editor history checksum mismatch.');
    }
    final checkpoint = EditorHistoryCheckpoint.decode(json);
    if (checkpoint.documentId != documentId ||
        checkpoint.ownerId != ownerId ||
        checkpoint.headOperationId != row.read<String>('head_operation_id')) {
      throw const FormatException('Editor history row scope mismatch.');
    }
    await _validate(checkpoint);
    return checkpoint;
  });
}
