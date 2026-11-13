import 'dart:convert';

import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/note_page.dart';
import '../../features/notebook/domain/notebook.dart';
import 'editor_sqlite_projector.dart';
import 'operation_protocol.dart';
import 'operation_store.dart';
import 'v2_outbox_conflict_policy.dart';

/// Preserve the optimistic notebook and original envelopes before deletion.
abstract final class V2DeleteConflictArchive {
  /// Apply the same lossless deletion policy for account and Share editors.
  static Future<void> applyRemote(
    OperationEnvelope operation,
    List<OperationEnvelope> pending,
    int cursor, {
    required NotebookRepository repository,
    required EditorSqliteProjector projector,
  }) async {
    final sourceMoves = await OperationStore(
      repository.database,
    ).movesAfterSourceDeletion(operation, cursor);
    final movedIds = sourceMoves.map((move) => move.objectId).toSet();
    final sourceConflict =
        sourceMoves.isNotEmpty &&
        pending.every(
          (local) =>
              V2OutboxConflictPolicy.canApply(operation, [local]) ||
              (local.documentId == operation.documentId &&
                  local.kind.target == OperationTarget.object &&
                  movedIds.contains(local.objectId)),
        );
    final canApply = V2OutboxConflictPolicy.canApply(operation, pending);
    final destructivePending = pending.any(
      (local) =>
          operation.kind == OperationKind.documentDelete ||
          (operation.kind == OperationKind.objectDelete &&
              local.objectId == operation.objectId) ||
          (operation.kind == OperationKind.pageDelete &&
              (local.pageId == operation.objectId ||
                  local.payload['toPageId'] == operation.objectId)),
    );
    if (!canApply &&
        !sourceConflict &&
        operation.kind != OperationKind.documentDelete &&
        !V2OutboxConflictPolicy.canArchiveObjectDelete(operation, pending) &&
        !V2OutboxConflictPolicy.canArchiveMoveDestinationDelete(
          operation,
          pending,
        )) {
      throw StateError('Remote v2 operation awaits local outbox ACK.');
    }
    if (!canApply || destructivePending || sourceMoves.isNotEmpty) {
      await archive(
        operation,
        {
          for (final op in [...pending, ...sourceMoves]) op.operationId: op,
        }.values.toList(),
        repository: repository,
        projector: projector,
      );
    }
    await projector.removeMovesAfterSourceDeletion(operation, sourceMoves);
    await projector.apply(operation);
  }

  static Future<List<Map<String, dynamic>>> read(
    NotebookRepository repository,
  ) async {
    final database = repository.database;
    final table = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE name = 'v2_delete_conflicts'",
        )
        .getSingleOrNull();
    if (table == null) return [];
    final rows = await database
        .customSelect('SELECT * FROM v2_delete_conflicts ORDER BY operation_id')
        .get();
    return [for (final row in rows) row.data];
  }

  static Future<void> archive(
    OperationEnvelope operation,
    List<OperationEnvelope> pending, {
    required NotebookRepository repository,
    required EditorSqliteProjector projector,
  }) async {
    final notebook = await repository.getNotebook(operation.documentId);
    if (notebook == null ||
        repository.lastCorruptNotebookIds.contains(operation.documentId)) {
      throw StateError(
        'Cannot archive a delete conflict with an unreadable notebook.',
      );
    }
    final database = repository.database;
    await database.customStatement(
      'CREATE TABLE IF NOT EXISTS v2_delete_conflicts ('
      'operation_id TEXT PRIMARY KEY, document_id TEXT NOT NULL, '
      'remote_json TEXT NOT NULL, local_json TEXT NOT NULL, notebook_json TEXT)',
    );
    await database.customStatement(
      'INSERT INTO v2_delete_conflicts '
      '(operation_id, document_id, remote_json, local_json, notebook_json) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        operation.operationId,
        operation.documentId,
        jsonEncode(operation.toJson()),
        jsonEncode([for (final item in pending) item.toJson()]),
        jsonEncode(
          await _recoveryNotebookSnapshot(notebook, repository, projector),
        ),
      ],
    );
  }

  static Future<Map<String, dynamic>> _recoveryNotebookSnapshot(
    Notebook source,
    NotebookRepository repository,
    EditorSqliteProjector projector,
  ) async {
    final pages = <NotePage>[];
    for (final page in source.pages) {
      final blocks = [...page.textBlocks];
      for (var i = 0; i < blocks.length; i++) {
        final text = blocks[i];
        if (text.deltaJson == null) {
          continue;
        }
        final delta = jsonDecode(text.deltaJson!) as List<dynamic>;
        for (final entry in delta) {
          final insert = (entry as Map)['insert'];
          if (insert is! Map) {
            continue;
          }
          final assetId = OperationEnvelope.embedAssetId(insert);
          final receipt = await projector.localAssetReceipt(
            documentId: source.uid,
            assetId: assetId,
          );
          if (receipt == null) {
            throw StateError('Cannot archive an unverified Quill attachment.');
          }
          final bytes = await projector.verifiedUploadBytes(receipt);
          final mediaType = receipt['mediaType'];
          entry['insert'] = {
            insert.keys.single: 'data:$mediaType;base64,${base64Encode(bytes)}',
          };
        }
        blocks[i] = text.copyWith(deltaJson: jsonEncode(delta));
      }
      pages.add(page.copyWith(textBlocks: blocks));
    }
    return repository.encodeSelfContainedBackup([
      source.copyWith(pages: pages),
    ]).single;
  }
}
