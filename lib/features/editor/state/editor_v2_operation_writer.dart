import '../../../data/sync/editor_sqlite_projector.dart';
import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/operation_store.dart';
import '../../../data/sync/sync_engine.dart';
import '../../notebook/domain/note_page.dart';
import 'editor_actions.dart';
import 'editor_operation_bridge.dart';

/// Opt-in transaction boundary for already migrated v2 notebook editors.
///
/// The editor must use this writer instead of legacy snapshot saves. It
/// converts a committed page state to durable intents and persists the
/// projection, actor sequence, and outbox through the same SQLite connection.
/// This class does not activate v2 for existing v1 documents.
class EditorV2OperationWriter {
  EditorV2OperationWriter({
    required this.syncEngine,
    required this.projector,
    EditorOperationBridge? bridge,
  }) : _bridge = bridge ?? EditorOperationBridge() {
    if (!identical(syncEngine.store.database, projector.database)) {
      throw ArgumentError('Editor and journal must share one SQLite database.');
    }
  }

  final SyncEngine syncEngine;
  final EditorSqliteProjector projector;
  final EditorOperationBridge _bridge;

  Future<List<OperationEnvelope>> writeAction({
    required String documentId,
    required EditorAction action,
    required NotePage before,
    required NotePage after,
  }) async {
    final atoms = await _textAtoms(
      documentId: documentId,
      before: before,
      after: after,
    );
    final drafts = _bridge.planAction(
      action: action,
      before: before,
      after: after,
      textAtomsById: atoms,
    );
    return _commit(documentId, drafts);
  }

  /// Used by Quill's coalesced edits and non-undoable page metadata changes.
  Future<List<OperationEnvelope>> writePageChange({
    required String documentId,
    required NotePage before,
    required NotePage after,
  }) async {
    final atoms = await _textAtoms(
      documentId: documentId,
      before: before,
      after: after,
    );
    final drafts = _bridge.planPageChange(
      before: before,
      after: after,
      textAtomsById: atoms,
    );
    return _commit(documentId, drafts);
  }

  Future<List<OperationEnvelope>> writeCreatePage({
    required String documentId,
    required NotePage page,
  }) => _commit(documentId, _bridge.planCreatePage(page));

  Future<List<OperationEnvelope>> writeDeletePage({
    required String documentId,
    required String pageId,
  }) => _commit(documentId, [_bridge.planDeletePage(pageId)]);

  Future<List<OperationEnvelope>> _commit(
    String documentId,
    List<LocalOperationDraft> drafts,
  ) {
    if (drafts.isEmpty) {
      return Future.value(const <OperationEnvelope>[]);
    }
    return syncEngine.writeLocalBatch(
      documentId: documentId,
      operations: drafts,
      apply: projector.apply,
    );
  }

  Future<Map<String, Map<String, dynamic>>> _textAtoms({
    required String documentId,
    required NotePage before,
    required NotePage after,
  }) async {
    final latest = {
      for (final text in after.textBlocks) text.id: text,
    };
    final result = <String, Map<String, dynamic>>{};
    for (final old in before.textBlocks) {
      final changed = latest[old.id];
      if (changed == null ||
          (changed.text == old.text && changed.deltaJson == old.deltaJson)) {
        continue;
      }
      result[old.id] = await syncEngine.store.textAtoms(
        documentId: documentId,
        pageId: before.id,
        objectId: old.id,
      );
    }
    return result;
  }
}
