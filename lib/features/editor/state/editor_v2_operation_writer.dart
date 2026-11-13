import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import '../../../data/sync/verified_editor_asset_buffer.dart';
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
    this.onCommitted,
    EditorOperationBridge? bridge,
  }) : _bridge = bridge ?? EditorOperationBridge() {
    if (!identical(syncEngine.store.database, projector.database)) {
      throw ArgumentError('Editor and journal must share one SQLite database.');
    }
  }

  final SyncEngine syncEngine;
  final EditorSqliteProjector projector;
  final OperationAssetGateway? assetGateway;

  /// Called after a successful atomic journal and SQLite commit.
  /// The callback must not cause a durable gesture to be retried.
  final void Function(String, List<OperationEnvelope>)? onCommitted;
  final EditorOperationBridge _bridge;
  final Map<String, Map<String, VerifiedEditorAsset>> _registeredAssets = {};

  /// Stages a new inline import without network or a premature journal write.
  /// The referencing Quill gesture persists these bytes with its outbox.
  VerifiedEditorAsset stageQuillAsset({
    required String documentId,
    required Uint8List bytes,
    required String embedType,
  }) {
    if (bytes.isEmpty ||
        bytes.length > OperationAssetGateway.maximumAssetBytes) {
      throw ArgumentError('Invalid inline asset size.');
    }
    final mime = VerifiedEditorAssetBuffer.inferMediaType(bytes);
    if ((embedType != 'image' && embedType != 'pdf') ||
        (embedType == 'pdf'
            ? mime != 'application/pdf'
            : !mime.startsWith('image/'))) {
      throw const FormatException('Inline embed type differs from its bytes.');
    }
    final buffer = projector.verifiedAssetBuffer;
    if (buffer == null) {
      throw StateError('Verified asset staging has not been installed.');
    }
    final asset = VerifiedEditorAsset(
      assetId: const Uuid().v4(),
      sha256: crypto.sha256.convert(bytes).toString(),
      sizeBytes: bytes.length,
      mediaType: mime,
    );
    registerVerifiedAsset(
      documentId: documentId,
      objectId: asset.assetId,
      asset: asset,
    );
    buffer.stage(receipt: asset.attachPayload, bytes: bytes);
    return asset;
  }

  /// Previews locally verified imports before autosave, then uses durable bytes.
  Future<Uint8List> quillAssetBytes({
    required String documentId,
    required String pageId,
    required String objectId,
    required String assetId,
  }) async {
    final staged = _registeredAssets[documentId]?[assetId];
    if (staged != null) {
      final buffer = projector.verifiedAssetBuffer;
      if (buffer == null) {
        throw StateError('Verified asset staging has not been installed.');
      }
      return buffer.requireBytes(staged.attachPayload);
    }
    return projector.verifiedTextAssetBytes(
      documentId: documentId,
      pageId: pageId,
      objectId: objectId,
      assetId: assetId,
    );
  }

  /// Validates copied references without importing assets from another scope.
  /// A freshly pasted file may still be staged before its first autosave.
  Future<Map<String, dynamic>> verifyQuillAssetReference({
    required String documentId,
    required String assetId,
    required String embedType,
    required int byteLimit,
  }) async {
    final staged = _registeredAssets[documentId]?[assetId];
    final receipt =
        staged?.attachPayload ??
        await projector.localAssetReceipt(
          documentId: documentId,
          assetId: assetId,
        );
    if (receipt == null ||
        byteLimit < 1 ||
        (receipt['sizeBytes'] as int) > byteLimit ||
        (embedType == 'pdf'
            ? receipt['mediaType'] != 'application/pdf'
            : embedType != 'image' ||
                  !const {
                    'image/png',
                    'image/jpeg',
                    'image/webp',
                  }.contains(receipt['mediaType']))) {
      throw const FormatException(
        'Pasted asset is unavailable, too large or has a different type.',
      );
    }
    if (staged != null) {
      final buffer = projector.verifiedAssetBuffer;
      if (buffer == null) {
        throw StateError('Verified asset staging has not been installed.');
      }
      buffer.requireBytes(receipt);
    } else {
      await projector.verifiedUploadBytes(receipt);
    }
    return receipt;
  }

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
  ) => {...?_registeredAssets[documentId], ...explicit};

  /// Reuses only assets previously committed in this document, including
  /// embeds detached by deletion. New imports still require verified staging.
  Future<Map<String, VerifiedEditorAsset>> _prepareAssets({
    required String documentId,
    required Iterable<NotePage> before,
    required Iterable<NotePage> after,
    required Map<String, VerifiedEditorAsset> verifiedAssets,
  }) async {
    await _prepareImageAssets(
      documentId: documentId,
      before: before,
      after: after,
      verifiedAssets: verifiedAssets,
    );
    final assets = _assetsFor(documentId, verifiedAssets);
    final previous = <String, TextBlock>{
      for (final page in before)
        for (final block in page.textBlocks) block.id: block,
    };
    for (final page in after) {
      for (final block in page.textBlocks) {
        final old = previous[block.id];
        if (old != null && old.deltaJson == block.deltaJson) {
          continue;
        }
        final oldEmbeds = EditorOperationBridge.quillEmbeds(old?.deltaJson);
        final nextEmbeds = EditorOperationBridge.quillEmbeds(block.deltaJson);
        for (final id in nextEmbeds.keys) {
          if (oldEmbeds.containsKey(id) || assets.containsKey(id)) {
            continue;
          }
          final receipt = await projector.localAssetReceipt(
            documentId: documentId,
            assetId: id,
          );
          if (receipt == null) {
            throw StateError('Quill asset has no verified document history.');
          }
          final buffer = projector.verifiedAssetBuffer;
          if (buffer == null) {
            throw StateError('Verified asset staging has not been installed.');
          }
          buffer.stage(
            receipt: receipt,
            bytes: await projector.verifiedUploadBytes(receipt),
          );
          assets[id] = VerifiedEditorAsset(
            assetId: id,
            sha256: receipt['sha256'] as String,
            sizeBytes: receipt['sizeBytes'] as int,
            mediaType: receipt['mediaType'] as String,
          );
        }
      }
    }
    return assets;
  }

  /// Verifies local media before the SQLite batch, without requiring network.
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
        if (old != null && EditorOperationBridge.sameImageContent(old, image)) {
          continue;
        }
        final verified =
            verifiedAssets[image.id] ??
            _registeredAssets[documentId]?[image.id];
        if (verified != null) {
          // A retry must never commit the receipt of an older image edit.
          if (image.imageMime != null &&
              image.imageMime != verified.mediaType) {
            throw StateError('The verified media type has changed.');
          }
          final localBytes =
              image.bytes ??
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
        final buffer = projector.verifiedAssetBuffer;
        if (buffer == null) {
          // The bridge will reject this edit without touching SQLite.
          continue;
        }
        final extension = (image.imageExt ?? image.path.split('.').last)
            .toLowerCase();
        final mime =
            image.imageMime ??
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
        final bytes =
            image.bytes ??
            (kIsWeb || image.path.isEmpty
                ? (throw StateError('Missing image bytes for v2 upload.'))
                : await File(image.path).readAsBytes());
        final receipt = <String, dynamic>{
          'assetId': const Uuid().v4(),
          'sha256': crypto.sha256.convert(bytes).toString(),
          'sizeBytes': bytes.length,
          'mediaType': mime,
        };
        buffer.stage(receipt: receipt, bytes: Uint8List.fromList(bytes));
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

  /// Boots a new notebook directly into the v2 document journal.
  ///
  /// The first document, page, content and outbox share one transaction.
  /// Never call legacy createNotebook() for this identity beforehand.
  Future<List<OperationEnvelope>> writeCreateNotebook({
    required Notebook notebook,
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
    Future<void> Function(List<OperationEnvelope>)? onCommittedInTransaction,
  }) async {
    if (notebook.uid.isEmpty ||
        notebook.pages.isEmpty ||
        notebook.kind.index > 2 ||
        notebook.title.isEmpty ||
        notebook.folder.isEmpty) {
      throw ArgumentError('Invalid operational notebook identity or kind.');
    }
    final assets = await _prepareAssets(
      documentId: notebook.uid,
      before: const <NotePage>[],
      after: notebook.pages,
      verifiedAssets: verifiedAssets,
    );
    final drafts = <LocalOperationDraft>[
      LocalOperationDraft(
        kind: OperationKind.documentCreate,
        payload: {
          'value': {
            'title': notebook.title,
            'folder': notebook.folder,
            'kindIndex': notebook.kind.index,
            'createdAt': notebook.createdAt.toUtc().toIso8601String(),
          },
        },
      ),
      for (final page in notebook.pages)
        ..._bridge.planCreatePage(page, verifiedAssets: assets),
    ];
    return _commit(
      notebook.uid,
      drafts,
      onCommittedInTransaction: onCommittedInTransaction,
    );
  }

  Future<List<OperationEnvelope>> writeDeleteNotebook({
    required String documentId,
    Future<void> Function(List<OperationEnvelope>)? onCommittedInTransaction,
  }) => _commit(documentId, [
    LocalOperationDraft(kind: OperationKind.documentDelete, payload: const {}),
  ], onCommittedInTransaction: onCommittedInTransaction);

  /// Commits a multi-page gesture and stable-ID ink moves in one batch.
  ///
  /// Ink stays unchanged during a move. Image geometry may change, but
  /// its verified asset ID and binary content must remain identical.
  /// Text moves preserve their CRDT identity and immutable atom history.
  /// Optional local checkpoint writes run in the operation transaction before
  /// callbacks that notify the UI or backup; failure rolls back the whole batch.
  Future<List<OperationEnvelope>> writeNotebookChange({
    required Notebook before,
    required Notebook after,
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
    String? revertsOperationId,
    Future<void> Function(List<OperationEnvelope>)? onCommittedInTransaction,
  }) async {
    if (before.uid != after.uid ||
        before.kind != after.kind ||
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
    final assets = await _prepareAssets(
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
      if (from != null &&
          to != null &&
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
      } else if (oldTexts[entry.key] case final oldText?) {
        final nextText = newTexts[entry.key];
        if (nextText == null ||
            oldText.text != nextText.text ||
            oldText.deltaJson != nextText.deltaJson) {
          throw UnsupportedError(
            'Cross-page text moves cannot edit CRDT contents.',
          );
        }
        movedTextIds.add(entry.key);
      } else {
        final oldImage = oldImages[entry.key];
        final newImage = newImages[entry.key];
        if (oldImage == null ||
            newImage == null ||
            oldImage.ocrText != newImage.ocrText ||
            !EditorOperationBridge.sameImageContent(oldImage, newImage)) {
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
    final drafts = <LocalOperationDraft>[
      if (before.title != after.title || before.folder != after.folder)
        LocalOperationDraft(
          kind: OperationKind.documentSet,
          payload: {
            'properties': {
              if (before.title != after.title) 'title': after.title,
              if (before.folder != after.folder) 'folder': after.folder,
            },
          },
        ),
    ];
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
        drafts.add(
          LocalOperationDraft(
            kind: OperationKind.objectMove,
            pageId: origin,
            objectId: stroke.id,
            payload: {'toPageId': page.id, 'sortIndex': index},
          ),
        );
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
        drafts.add(
          LocalOperationDraft(
            kind: OperationKind.objectMove,
            pageId: oldObjects[block.id]!,
            objectId: block.id,
            payload: {'toPageId': page.id, 'sortIndex': index},
          ),
        );
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
        drafts.add(
          LocalOperationDraft(
            kind: OperationKind.objectMove,
            pageId: oldObjects[image.id]!,
            objectId: image.id,
            payload: {'toPageId': page.id, 'sortIndex': index},
          ),
        );
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
      drafts.addAll(
        _bridge.planPageChange(
          before: baseline,
          after: page,
          textAtomsById: atoms,
          verifiedAssets: assets,
          existingAssetIds: await _existingImageAssets(
            documentId: after.uid,
            before: baseline,
            after: page,
          ),
        ),
      );
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
          drafts.add(
            LocalOperationDraft(
              kind: OperationKind.objectReorder,
              pageId: page.id,
              objectId: stroke.id,
              payload: {
                'properties': {'sortIndex': index},
              },
            ),
          );
        }
        for (var index = 0; index < page.textBlocks.length; index++) {
          final block = page.textBlocks[index];
          if (movedTextIds.contains(block.id) ||
              drafts.any(
                (draft) =>
                    draft.pageId == page.id &&
                    draft.objectId == block.id &&
                    draft.kind == OperationKind.objectSet &&
                    (draft.payload['properties'] as Map).containsKey(
                      'sortIndex',
                    ),
              )) {
            continue;
          }
          drafts.add(
            LocalOperationDraft(
              kind: OperationKind.objectSet,
              pageId: page.id,
              objectId: block.id,
              payload: {
                'properties': {'sortIndex': index},
              },
            ),
          );
        }
        for (var index = 0; index < page.imageBlocks.length; index++) {
          final image = page.imageBlocks[index];
          if (movedImageIds.contains(image.id) ||
              drafts.any(
                (draft) =>
                    draft.pageId == page.id &&
                    draft.objectId == image.id &&
                    draft.kind == OperationKind.objectSet &&
                    (draft.payload['properties'] as Map).containsKey(
                      'sortIndex',
                    ),
              )) {
            continue;
          }
          drafts.add(
            LocalOperationDraft(
              kind: OperationKind.objectSet,
              pageId: page.id,
              objectId: image.id,
              payload: {
                'properties': {'sortIndex': index},
              },
            ),
          );
        }
      }
    }
    for (final page in before.pages) {
      if (!newPages.containsKey(page.id)) {
        drafts.add(_bridge.planDeletePage(page.id));
      }
    }
    return _commit(after.uid, [
      for (final draft in drafts)
        LocalOperationDraft(
          kind: draft.kind,
          payload: draft.payload,
          pageId: draft.pageId,
          objectId: draft.objectId,
          dependencies: draft.dependencies,
          revertsOperationId: revertsOperationId ?? draft.revertsOperationId,
        ),
    ], onCommittedInTransaction: onCommittedInTransaction);
  }

  Future<Map<String, String>> _existingImageAssets({
    required String documentId,
    required NotePage before,
    required NotePage after,
  }) async {
    final previous = {for (final image in before.imageBlocks) image.id: image};
    final result = <String, String>{};
    for (final next in after.imageBlocks) {
      final old = previous[next.id];
      if (old == null ||
          (old.ocrText == next.ocrText &&
              EditorOperationBridge.sameImageContent(old, next))) {
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
    final assets = await _prepareAssets(
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
      verifiedAssets: assets,
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
    final assets = await _prepareAssets(
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
      verifiedAssets: assets,
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
    final assets = await _prepareAssets(
      documentId: documentId,
      before: const <NotePage>[],
      after: [page],
      verifiedAssets: verifiedAssets,
    );
    return _commit(
      documentId,
      _bridge.planCreatePage(page, verifiedAssets: assets),
    );
  }

  Future<List<OperationEnvelope>> writeDeletePage({
    required String documentId,
    required String pageId,
  }) => _commit(documentId, [_bridge.planDeletePage(pageId)]);

  Future<List<OperationEnvelope>> _commit(
    String documentId,
    List<LocalOperationDraft> drafts, {
    Future<void> Function(List<OperationEnvelope>)? onCommittedInTransaction,
  }) async {
    if (drafts.isEmpty && onCommittedInTransaction == null) {
      return const <OperationEnvelope>[];
    }
    final committed = await syncEngine.writeLocalBatch(
      documentId: documentId,
      operations: drafts,
      apply: projector.apply,
      onCommittedInTransaction: onCommittedInTransaction,
    );
    final registered = _registeredAssets[documentId];
    if (registered != null) {
      for (final operation in committed) {
        if (operation.kind != OperationKind.assetAttach) {
          continue;
        }
        for (final key in {operation.objectId, operation.payload['assetId']}) {
          final previous = registered[key];
          if (previous != null &&
              const DeepCollectionEquality().equals(
                previous.attachPayload,
                operation.payload,
              )) {
            registered.remove(key);
          }
        }
      }
      if (registered.isEmpty) {
        _registeredAssets.remove(documentId);
      }
    }
    if (committed.isNotEmpty && onCommitted != null) {
      try {
        onCommitted!(
          documentId,
          List<OperationEnvelope>.unmodifiable(committed),
        );
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'editor v2',
            context: ErrorDescription('notifying a durable journal commit'),
          ),
        );
      }
    }
    return committed;
  }

  Future<Map<String, Map<String, dynamic>>> _textAtoms({
    required String documentId,
    required NotePage before,
    required NotePage after,
  }) async {
    final latest = {for (final text in after.textBlocks) text.id: text};
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
