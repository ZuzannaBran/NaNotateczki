import 'dart:convert';

import 'package:collection/collection.dart';

import '../../../data/sync/editor_sqlite_projector.dart';
import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/operation_store.dart';
import '../../../data/sync/operation_text_sequence.dart';
import '../../../data/sync/sync_engine.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/notebook.dart';
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

  /// Commits the complete effect of a multi-page gesture atomically.
  ///
  /// Moves that retain an object ID on a different page require object.move
  /// and must never be emulated as delete/create with a partial commit.
  Future<List<OperationEnvelope>> writeNotebookChange({
    required Notebook before,
    required Notebook after,
  }) async {
    if (before.uid != after.uid ||
        before.kind != after.kind ||
        before.title != after.title ||
        before.folder != after.folder ||
        after.pages.isEmpty) {
      throw ArgumentError('Unsupported notebook identity or metadata edit.');
    }
    Map<String, NotePage> uniquePages(Notebook notebook) {
      final result = <String, NotePage>{};
      for (final page in notebook.pages) {
        if (page.id.isEmpty || result.containsKey(page.id)) {
          throw StateError('Duplicate or missing notebook page identity.');
        }
        result[page.id] = page;
      }
      return result;
    }

    Map<String, String> objectPages(Notebook notebook) {
      final result = <String, String>{};
      for (final page in notebook.pages) {
        final ids = [
          ...page.inkStrokes.map((stroke) => stroke.id),
          ...page.textBlocks.map((block) => block.id),
          ...page.imageBlocks.map((block) => block.id),
        ];
        for (final id in ids) {
          if (id.isEmpty || result.containsKey(id)) {
            throw StateError('Duplicate or missing object identity.');
          }
          result[id] = page.id;
        }
      }
      return result;
    }

    final oldPages = uniquePages(before);
    final newPages = uniquePages(after);
    final oldObjects = objectPages(before);
    final newObjects = objectPages(after);
    for (final entry in newObjects.entries) {
      final origin = oldObjects[entry.key];
      if (origin != null && origin != entry.value) {
        throw UnsupportedError('Cross-page objects require object.move.');
      }
    }
    final originalOrder = [
      for (final page in before.pages)
        if (newPages.containsKey(page.id)) page.id,
    ];
    final nextOrder = [
      for (final page in after.pages)
        if (oldPages.containsKey(page.id)) page.id,
    ];
    if (!const ListEquality<String>().equals(originalOrder, nextOrder)) {
      throw UnsupportedError('Page reordering is not yet in v2.');
    }

    final drafts = <LocalOperationDraft>[];
    for (final page in after.pages) {
      final old = oldPages[page.id];
      if (old == null) {
        drafts.addAll(_bridge.planCreatePage(page));
      } else {
        final atoms = await _textAtoms(
          documentId: after.uid,
          before: old,
          after: page,
        );
        drafts.addAll(_bridge.planPageChange(
          before: old,
          after: page,
          textAtomsById: atoms,
        ));
      }
    }
    for (final page in before.pages) {
      if (!newPages.containsKey(page.id)) {
        drafts.add(_bridge.planDeletePage(page.id));
      }
    }
    return _commit(after.uid, drafts);
  }

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
      final atoms = await syncEngine.store.textAtoms(
        documentId: documentId,
        pageId: before.id,
        objectId: old.id,
      );
      if (old.deltaJson != null &&
          !const DeepCollectionEquality().equals(
            jsonDecode(old.deltaJson!),
            OperationTextSequence.renderDelta(atoms),
          )) {
        throw StateError('The text edit started from stale Quill formatting.');
      }
      result[old.id] = atoms;
    }
    return result;
  }
}
