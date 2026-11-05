import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../data/sync/editor_sqlite_projector.dart';
import '../../../data/sync/operation_asset_gateway.dart';
import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/operation_store.dart';
import '../../../data/sync/operation_text_sequence.dart';
import '../../../data/sync/sync_engine.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/ink_stroke.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/text_block.dart';
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
    this.assetGateway,
    EditorOperationBridge? bridge,
  }) : _bridge = bridge ?? EditorOperationBridge() {
    if (!identical(syncEngine.store.database, projector.database)) {
      throw ArgumentError('Editor and journal must share one SQLite database.');
    }
  }

  final SyncEngine syncEngine;
  final EditorSqliteProjector projector;
  final OperationAssetGateway? assetGateway;
  final EditorOperationBridge _bridge;
  final Map<String, Map<String, VerifiedEditorAsset>> _registeredAssets = {};

  /// Call after a verified upload has been staged for the same document.
  /// The receipt survives a rolled-back editor gesture for safe retry.
  void registerVerifiedAsset({
    required String documentId,
    required String objectId,
    required VerifiedEditorAsset asset,
  }) {
    if (documentId.isEmpty || objectId.isEmpty) {
      throw ArgumentError('Asset registration requires stable identities.');
    }
    OperationEnvelope.validateV2Payload(
      kind: OperationKind.assetAttach,
      payload: asset.attachPayload,
      documentId: documentId,
      pageId: 'staged-editor-page',
      objectId: objectId,
    );
    final registered = _registeredAssets.putIfAbsent(
      documentId,
      () => <String, VerifiedEditorAsset>{},
    );
    final previous = registered[objectId];
    if (previous != null &&
        !const DeepCollectionEquality().equals(
          previous.attachPayload,
          asset.attachPayload,
        )) {
      throw StateError('Pending asset identity cannot change on retry.');
    }
    registered[objectId] = asset;
  }

  Map<String, VerifiedEditorAsset> _assetsFor(
    String documentId,
    Map<String, VerifiedEditorAsset> explicit,
  ) => {
    ...?_registeredAssets[documentId],
    ...explicit,
  };

  /// Stages new or replaced image bytes before opening the SQLite batch.
  ///
  /// Failed HTTP/checksum validation leaves the durable projection and outbox
  /// untouched. An already verified receipt is reused on a local retry.
  Future<void> _prepareImageAssets({
    required String documentId,
    required Iterable<NotePage> before,
    required Iterable<NotePage> after,
    required Map<String, VerifiedEditorAsset> verifiedAssets,
  }) async {
    final previous = <String, ImageBlock>{
      for (final page in before)
        for (final image in page.imageBlocks) image.id: image,
    };
    for (final page in after) {
      for (final image in page.imageBlocks) {
        final old = previous[image.id];
        if (old != null && old.ocrText != image.ocrText) {
          throw UnsupportedError('OCR metadata is not yet a v2 operation.');
        }
        if (old != null &&
            old.path == image.path &&
            old.imageMime == image.imageMime &&
            old.imageExt == image.imageExt &&
            const ListEquality<int>().equals(old.bytes, image.bytes)) {
          continue;
        }
        final verified = verifiedAssets[image.id] ??
            _registeredAssets[documentId]?[image.id];
        if (verified != null) {
          // A retry must never commit the receipt of an older image edit.
          if (image.imageMime != null &&
              image.imageMime != verified.mediaType) {
            throw StateError('The verified media type has changed.');
          }
          final localBytes = image.bytes ??
              (image.path.isEmpty || kIsWeb
                  ? null
                  : await File(image.path).readAsBytes());
          if (localBytes != null &&
              (localBytes.length != verified.sizeBytes ||
                  crypto.sha256.convert(localBytes).toString() !=
                      verified.sha256)) {
            throw StateError('The verified image has changed since upload.');
          }
          continue;
        }
        final gateway = assetGateway;
        final buffer = projector.verifiedAssetBuffer;
        if (gateway == null || buffer == null) {
          // The bridge will reject this edit without touching SQLite.
          continue;
        }
        final extension =
            (image.imageExt ?? image.path.split('.').last).toLowerCase();
        final mime = image.imageMime ??
            switch (extension) {
              'png' => 'image/png',
              'jpg' || 'jpeg' => 'image/jpeg',
              'webp' => 'image/webp',
              'pdf' => 'application/pdf',
              _ => '',
            };
        if (!OperationAssetGateway.supportedMimeTypes.contains(mime)) {
          throw UnsupportedError('Unsupported v2 image/PDF media type.');
        }
        final bytes = image.bytes ??
            (kIsWeb || image.path.isEmpty
                ? (throw StateError('Missing image bytes for v2 upload.'))
                : await File(image.path).readAsBytes());
        final receipt = await gateway.uploadAndStage(
          assetId: const Uuid().v4(),
          bytes: bytes,
          mediaType: mime,
          buffer: buffer,
        );
        registerVerifiedAsset(
          documentId: documentId,
          objectId: image.id,
          asset: VerifiedEditorAsset(
            assetId: receipt['assetId'] as String,
            sha256: receipt['sha256'] as String,
            sizeBytes: receipt['sizeBytes'] as int,
            mediaType: receipt['mediaType'] as String,
          ),
        );
      }
    }
  }

  /// Commits a multi-page gesture and stable-ID ink moves in one batch.
  ///
  /// Ink stays unchanged during a move. Image geometry may change, but
  /// its verified asset ID and binary content must remain identical.
  /// Text moves preserve their CRDT identity and immutable atom history.
  Future<List<OperationEnvelope>> writeNotebookChange({
    required Notebook before,
    required Notebook after,
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
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
    await _prepareImageAssets(
      documentId: after.uid,
      before: before.pages,
      after: after.pages,
      verifiedAssets: verifiedAssets,
    );

    final oldInk = <String, InkStroke>{
      for (final page in before.pages)
        for (final stroke in page.inkStrokes) stroke.id: stroke,
    };
    final newInk = <String, InkStroke>{
      for (final page in after.pages)
        for (final stroke in page.inkStrokes) stroke.id: stroke,
    };
    final oldTexts = <String, TextBlock>{
      for (final page in before.pages)
        for (final block in page.textBlocks) block.id: block,
    };
    final newTexts = <String, TextBlock>{
      for (final page in after.pages)
        for (final block in page.textBlocks) block.id: block,
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
    final movedTextIds = <String>{};
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
      } else if (oldTexts[entry.key] case final oldText?)
        {
          final nextText = newTexts[entry.key];
          if (nextText == null ||
              oldText.text != nextText.text ||
              oldText.deltaJson != nextText.deltaJson) {
            throw UnsupportedError(
              'Cross-page text moves cannot edit CRDT contents.',
            );
          }
          movedTextIds.add(entry.key);
        }
      else {
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
            'Cross-page moves require unchanged ink, text or image assets.',
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
          textBlocks: [
            for (final block in page.textBlocks)
              if (!movedTextIds.contains(block.id)) block,
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
      for (var index = 0; index < page.textBlocks.length; index++) {
        final block = page.textBlocks[index];
        if (!movedTextIds.contains(block.id)) {
          continue;
        }
        drafts.add(LocalOperationDraft(
          kind: OperationKind.objectMove,
          pageId: oldObjects[block.id]!,
          objectId: block.id,
          payload: {'toPageId': page.id, 'sortIndex': index},
        ));
        final current = staged[page.id]!;
        final nextTexts = List<TextBlock>.from(current.textBlocks);
        nextTexts.insert(
          index.clamp(0, nextTexts.length).toInt(),
          oldTexts[block.id]!,
        );
        staged[page.id] = current.copyWith(textBlocks: nextTexts);
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
        verifiedAssets: _assetsFor(after.uid, verifiedAssets),
        existingAssetIds: await _existingImageAssets(
          documentId: after.uid,
          before: baseline,
          after: page,
        ),
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
        for (var index = 0; index < page.textBlocks.length; index++) {
          final block = page.textBlocks[index];
          if (movedTextIds.contains(block.id) ||
              drafts.any((draft) =>
                  draft.pageId == page.id &&
                  draft.objectId == block.id &&
                  draft.kind == OperationKind.objectSet &&
                  (draft.payload['properties'] as Map)
                      .containsKey('sortIndex'))) {
            continue;
          }
          drafts.add(LocalOperationDraft(
            kind: OperationKind.objectSet,
            pageId: page.id,
            objectId: block.id,
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

  Future<Map<String, String>> _existingImageAssets({
    required String documentId,
    required NotePage before,
    required NotePage after,
  }) async {
    final previous = {
      for (final image in before.imageBlocks) image.id: image,
    };
    final result = <String, String>{};
    for (final next in after.imageBlocks) {
      final old = previous[next.id];
      if (old == null ||
          (old.path == next.path &&
              old.ocrText == next.ocrText &&
              old.imageMime == next.imageMime &&
              old.imageExt == next.imageExt &&
              const ListEquality<int>().equals(old.bytes, next.bytes))) {
        continue;
      }
      result[next.id] = await projector.verifiedImageAssetId(
        documentId: documentId,
        pageId: before.id,
        objectId: next.id,
      );
    }
    return result;
  }

  Future<List<OperationEnvelope>> writeAction({
    required String documentId,
    required EditorAction action,
    required NotePage before,
    required NotePage after,
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
  }) async {
    await _prepareImageAssets(
      documentId: documentId,
      before: [before],
      after: [after],
      verifiedAssets: verifiedAssets,
    );
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
      verifiedAssets: _assetsFor(documentId, verifiedAssets),
      existingAssetIds: await _existingImageAssets(
        documentId: documentId,
        before: before,
        after: after,
      ),
    );
    return _commit(documentId, drafts);
  }

  /// Used by Quill's coalesced edits and non-undoable page metadata changes.
  Future<List<OperationEnvelope>> writePageChange({
    required String documentId,
    required NotePage before,
    required NotePage after,
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
  }) async {
    await _prepareImageAssets(
      documentId: documentId,
      before: [before],
      after: [after],
      verifiedAssets: verifiedAssets,
    );
    final atoms = await _textAtoms(
      documentId: documentId,
      before: before,
      after: after,
    );
    final drafts = _bridge.planPageChange(
      before: before,
      after: after,
      textAtomsById: atoms,
      verifiedAssets: _assetsFor(documentId, verifiedAssets),
      existingAssetIds: await _existingImageAssets(
        documentId: documentId,
        before: before,
        after: after,
      ),
    );
    return _commit(documentId, drafts);
  }

  Future<List<OperationEnvelope>> writeCreatePage({
    required String documentId,
    required NotePage page,
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
  }) async {
    await _prepareImageAssets(
      documentId: documentId,
      before: const <NotePage>[],
      after: [page],
      verifiedAssets: verifiedAssets,
    );
    return _commit(
      documentId,
      _bridge.planCreatePage(
        page,
        verifiedAssets: _assetsFor(documentId, verifiedAssets),
      ),
    );
  }

  Future<List<OperationEnvelope>> writeDeletePage({
    required String documentId,
    required String pageId,
  }) => _commit(documentId, [_bridge.planDeletePage(pageId)]);

  Future<List<OperationEnvelope>> _commit(
    String documentId,
    List<LocalOperationDraft> drafts,
  ) async {
    if (drafts.isEmpty) {
      return const <OperationEnvelope>[];
    }
    final committed = await syncEngine.writeLocalBatch(
      documentId: documentId,
      operations: drafts,
      apply: projector.apply,
    );
    final registered = _registeredAssets[documentId];
    if (registered != null) {
      for (final operation in committed) {
        if (operation.kind != OperationKind.assetAttach) {
          continue;
        }
        final previous = registered[operation.objectId];
        if (previous != null &&
            const DeepCollectionEquality().equals(
              previous.attachPayload,
              operation.payload,
            )) {
          registered.remove(operation.objectId);
        }
      }
      if (registered.isEmpty) {
        _registeredAssets.remove(documentId);
      }
    }
    return committed;
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
