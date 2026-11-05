import 'dart:convert';

import 'package:collection/collection.dart';

import '../../../data/sync/editor_sqlite_projector.dart';
import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/operation_store.dart';
import '../../../data/sync/operation_text_sequence.dart';
import '../../../data/sync/sync_engine.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/ink_stroke.dart';
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

  /// Commits a multi-page gesture and stable-ID ink moves in one batch.
  ///
  /// Ink stays unchanged during a move. Image geometry may change, but
  /// its verified asset ID and binary content must remain identical.
  /// Text moves still require a cross-page CRDT checkpoint.
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

    final oldInk = <String, InkStroke>{
      for (final page in before.pages)
        for (final stroke in page.inkStrokes) stroke.id: stroke,
    };
    final newInk = <String, InkStroke>{
      for (final page in after.pages)
        for (final stroke in page.inkStrokes) stroke.id: stroke,
    };
    final oldImages = <String, ImageBlock>{
      for (final page in before.pages)
        for (final image in page.imageBlocks) image.id: image,
    };
    final newImages = <String, ImageBlock>{
      for (final page in after.pages)
        for (final image in page.imageBlocks) image.id: image,
    };
    final movedInkIds = <String>{};
    final movedImageIds = <String>{};
    final touchedPages = <String>{};
    for (final entry in newObjects.entries) {
      final origin = oldObjects[entry.key];
      if (origin == null || origin == entry.value) {
        continue;
      }
      final from = oldInk[entry.key];
      final to = newInk[entry.key];
      if (from != null && to != null &&
          from.color.toARGB32() == to.color.toARGB32() &&
          from.width == to.width &&
          from.tool == to.tool &&
          const DeepCollectionEquality().equals(
            [
              for (final point in from.points)
                [point.dx, point.dy, point.pressure],
            ],
            [
              for (final point in to.points)
                [point.dx, point.dy, point.pressure],
            ],
          )) {
        movedInkIds.add(entry.key);
      } else {
        final oldImage = oldImages[entry.key];
        final newImage = newImages[entry.key];
        if (oldImage == null || newImage == null ||
            oldImage.path != newImage.path ||
            oldImage.ocrText != newImage.ocrText ||
            oldImage.imageMime != newImage.imageMime ||
            oldImage.imageExt != newImage.imageExt ||
            !const ListEquality<int>().equals(
              oldImage.bytes,
              newImage.bytes,
            )) {
          throw UnsupportedError(
            'Cross-page moves require unchanged ink or image assets.',
          );
        }
        movedImageIds.add(entry.key);
      }
      touchedPages.add(origin);
      touchedPages.add(entry.value);
    }

    // Build the temporary pre-move projection without changing user pages.
    // Newly created destination pages must exist before object.move.
    final staged = <String, NotePage>{
      for (final page in before.pages)
        page.id: page.copyWith(
          inkStrokes: [
            for (final stroke in page.inkStrokes)
              if (!movedInkIds.contains(stroke.id)) stroke,
          ],
          imageBlocks: [
            for (final image in page.imageBlocks)
              if (!movedImageIds.contains(image.id)) image,
          ],
        ),
    };
    final drafts = <LocalOperationDraft>[];
    for (final page in after.pages) {
      if (!oldPages.containsKey(page.id)) {
        final empty = page.copyWith(
          inkStrokes: [],
          textBlocks: [],
          imageBlocks: [],
        );
        staged[page.id] = empty;
        drafts.addAll(_bridge.planCreatePage(empty));
      }
    }

    for (final page in after.pages) {
      for (var index = 0; index < page.inkStrokes.length; index++) {
        final stroke = page.inkStrokes[index];
        if (!movedInkIds.contains(stroke.id)) {
          continue;
        }
        final origin = oldObjects[stroke.id]!;
        drafts.add(LocalOperationDraft(
          kind: OperationKind.objectMove,
          pageId: origin,
          objectId: stroke.id,
          payload: {'toPageId': page.id, 'sortIndex': index},
        ));
        final current = staged[page.id]!;
        final nextInk = List<InkStroke>.from(current.inkStrokes);
        nextInk.insert(index.clamp(0, nextInk.length).toInt(), stroke);
        staged[page.id] = current.copyWith(inkStrokes: nextInk);
      }
      for (var index = 0; index < page.imageBlocks.length; index++) {
        final image = page.imageBlocks[index];
        if (!movedImageIds.contains(image.id)) {
          continue;
        }
        drafts.add(LocalOperationDraft(
          kind: OperationKind.objectMove,
          pageId: oldObjects[image.id]!,
          objectId: image.id,
          payload: {'toPageId': page.id, 'sortIndex': index},
        ));
        final current = staged[page.id]!;
        final nextImages = List<ImageBlock>.from(current.imageBlocks);
        nextImages.insert(
          index.clamp(0, nextImages.length).toInt(),
          oldImages[image.id]!,
        );
        staged[page.id] = current.copyWith(imageBlocks: nextImages);
      }
    }

    for (final page in after.pages) {
      final baseline = staged[page.id]!;
      final atoms = await _textAtoms(
        documentId: after.uid,
        before: baseline,
        after: page,
      );
      drafts.addAll(_bridge.planPageChange(
        before: baseline,
        after: page,
        textAtomsById: atoms,
      ));
      if (touchedPages.contains(page.id)) {
        // A move can shift the old sortIndex of an untouched stroke.
        // Re-state the final order using stable IDs, without recreation.
        for (var index = 0; index < page.inkStrokes.length; index++) {
          final stroke = page.inkStrokes[index];
          if (movedInkIds.contains(stroke.id) ||
              drafts.any(
                (draft) =>
                    draft.pageId == page.id &&
                    draft.objectId == stroke.id &&
                    draft.kind == OperationKind.objectReorder,
              )) {
            continue;
          }
          drafts.add(LocalOperationDraft(
            kind: OperationKind.objectReorder,
            pageId: page.id,
            objectId: stroke.id,
            payload: {
              'properties': {'sortIndex': index},
            },
          ));
        }
        for (var index = 0; index < page.imageBlocks.length; index++) {
          final image = page.imageBlocks[index];
          if (movedImageIds.contains(image.id) ||
              drafts.any((draft) =>
                  draft.pageId == page.id &&
                  draft.objectId == image.id &&
                  draft.kind == OperationKind.objectSet &&
                  (draft.payload['properties'] as Map)
                      .containsKey('sortIndex'))) {
            continue;
          }
          drafts.add(LocalOperationDraft(
            kind: OperationKind.objectSet,
            pageId: page.id,
            objectId: image.id,
            payload: {
              'properties': {'sortIndex': index},
            },
          ));
        }
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
