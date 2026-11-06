import 'dart:convert';

import 'package:collection/collection.dart';

import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/operation_store.dart';
import '../../../data/sync/operation_text_sequence.dart';
import '../../../data/sync/share_ink_edit_adapter.dart';
import '../../../data/sync/share_text_edit_adapter.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/text_block.dart';
import 'editor_actions.dart';

/// Metadata returned by a successful, checksummed v2 asset upload.
class VerifiedEditorAsset {
  const VerifiedEditorAsset({
    required this.assetId,
    required this.sha256,
    required this.sizeBytes,
    required this.mediaType,
  });

  final String assetId;
  final String sha256;
  final int sizeBytes;
  final String mediaType;

  Map<String, dynamic> get attachPayload => {
    'assetId': assetId,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    'mediaType': mediaType,
  };
}

/// Converts committed editor changes into the existing v2 intent vocabulary.
///
/// Planning is pure. The caller must commit the returned drafts using
/// SyncEngine.writeLocalBatch with a SQLite projection callback. Never call
/// this from pointer previews or keep a legacy snapshot writer alongside it.
class EditorOperationBridge {
  EditorOperationBridge({
    ShareInkEditAdapter? inkAdapter,
    ShareTextEditAdapter? textAdapter,
  }) : _ink = inkAdapter ?? ShareInkEditAdapter(),
       _text = textAdapter ?? ShareTextEditAdapter();

  final ShareInkEditAdapter _ink;
  final ShareTextEditAdapter _text;
  static const _bytes = ListEquality<int>();

  /// Covers all same-page EditorAction variants by their committed effect.
  /// Cross-page moves must use [planCrossPageImageMove] instead.
  List<LocalOperationDraft> planAction({
    required EditorAction action,
    required NotePage before,
    required NotePage after,
    Map<String, Map<String, dynamic>> textAtomsById = const {},
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
    Map<String, String> existingAssetIds = const {},
  }) {
    if (action is MoveImageBetweenPagesAction) {
      throw ArgumentError('Use planCrossPageImageMove for cross-page edits.');
    }
    return planPageChange(
      before: before,
      after: after,
      textAtomsById: textAtomsById,
      verifiedAssets: verifiedAssets,
      existingAssetIds: existingAssetIds,
    );
  }

  List<LocalOperationDraft> planPageChange({
    required NotePage before,
    required NotePage after,
    Map<String, Map<String, dynamic>> textAtomsById = const {},
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
    Map<String, String> existingAssetIds = const {},
  }) {
    if (before.id.isEmpty || before.id != after.id) {
      throw ArgumentError('A committed edit must preserve its page ID.');
    }
    _checkObjectIds(before);
    _checkObjectIds(after);
    final result = <LocalOperationDraft>[];
    final pageProperties = <String, dynamic>{
      if (before.title != after.title) 'title': after.title,
      if (before.isBookmarked != after.isBookmarked)
        'isBookmarked': after.isBookmarked,
    };
    if (pageProperties.isNotEmpty) {
      result.add(
        LocalOperationDraft(
          kind: OperationKind.pageSet,
          objectId: after.id,
          payload: {'properties': pageProperties},
        ),
      );
    }

    for (final intent in _ink.plan(before: before, after: after)) {
      result.add(
        LocalOperationDraft(
          kind: intent.kind,
          pageId: intent.pageId,
          objectId: intent.objectId,
          payload: intent.payload,
        ),
      );
    }

    final oldTexts = _index(before.textBlocks, (TextBlock b) => b.id);
    final newTexts = _index(after.textBlocks, (TextBlock b) => b.id);
    for (final id in oldTexts.keys) {
      if (!newTexts.containsKey(id)) {
        result.add(_delete(after.id, id));
      }
    }
    for (final entry in after.textBlocks.asMap().entries) {
      final block = entry.value;
      final old = oldTexts[block.id];
      final geometry = _textGeometry(block, entry.key);
      if (old == null) {
        result.add(
          _create(after.id, block.id, {'objectType': 'text', ...geometry}),
        );
        result.addAll(
          _attachQuillEmbeds(
            pageId: after.id,
            objectId: block.id,
            beforeDelta: null,
            afterDelta: block.deltaJson,
            verifiedAssets: verifiedAssets,
          ),
        );
        for (final intent in _text.plan(
          atoms: const {},
          newText: block.text,
          changedDeltaJson: block.deltaJson,
        )) {
          result.add(_textIntent(after.id, block.id, intent));
        }
        continue;
      }
      final oldIndex = before.textBlocks.indexWhere((b) => b.id == block.id);
      final changed = _diff(_textGeometry(old, oldIndex), geometry);
      if (changed.isNotEmpty) {
        result.add(_set(after.id, block.id, changed));
      }
      if (old.text != block.text || old.deltaJson != block.deltaJson) {
        final atoms = textAtomsById[block.id];
        if (atoms == null) {
          throw StateError('A text change needs the durable CRDT atom state.');
        }
        final atomText = OperationTextSequence.render(atoms);
        if (atomText != old.text &&
            (old.deltaJson == null ||
                !atomText.endsWith('\n') ||
                OperationTextSequence.withoutQuillTerminalNewline(atomText) !=
                    old.text)) {
          throw StateError('Stale text atom projection cannot be edited.');
        }
        result.addAll(
          _attachQuillEmbeds(
            pageId: after.id,
            objectId: block.id,
            beforeDelta: old.deltaJson,
            afterDelta: block.deltaJson,
            verifiedAssets: verifiedAssets,
          ),
        );
        for (final intent in _text.plan(
          atoms: atoms,
          newText: block.text,
          changedDeltaJson: block.deltaJson,
        )) {
          result.add(_textIntent(after.id, block.id, intent));
        }
        result.addAll(
          _detachUnusedQuillEmbeds(
            pageId: after.id,
            objectId: block.id,
            beforeDelta: old.deltaJson,
            afterDelta: block.deltaJson,
          ),
        );
      }
    }

    final oldImages = _index(before.imageBlocks, (ImageBlock b) => b.id);
    final newImages = _index(after.imageBlocks, (ImageBlock b) => b.id);
    for (final id in oldImages.keys) {
      if (!newImages.containsKey(id)) {
        result.add(_delete(after.id, id));
      }
    }
    for (final entry in after.imageBlocks.asMap().entries) {
      final image = entry.value;
      final old = oldImages[image.id];
      final geometry = _imageGeometry(image, entry.key);
      if (old == null) {
        final asset = verifiedAssets[image.id];
        if (asset == null) {
          throw StateError('Image/PDF must be uploaded and verified first.');
        }
        _validateImageAsset(image, asset);
        result.add(
          _create(after.id, image.id, {
            'objectType': 'image',
            'assetId': asset.assetId,
            ...geometry,
          }),
        );
        result.add(
          LocalOperationDraft(
            kind: OperationKind.assetAttach,
            pageId: after.id,
            objectId: image.id,
            payload: asset.attachPayload,
          ),
        );
        continue;
      }
      final oldIndex = before.imageBlocks.indexWhere((b) => b.id == image.id);
      final changed = _diff(_imageGeometry(old, oldIndex), geometry);
      if (!sameImageContent(old, image)) {
        final asset = verifiedAssets[image.id];
        final previousId = existingAssetIds[image.id];
        if (asset == null ||
            previousId == null ||
            previousId == asset.assetId) {
          throw StateError(
            'Image replacement needs a new verified asset and old asset ID.',
          );
        }
        _validateImageAsset(image, asset);
        OperationEnvelope.validateV2Payload(
          kind: OperationKind.assetDetach,
          payload: {'assetId': previousId},
          documentId: 'editor-bridge',
          pageId: after.id,
          objectId: image.id,
        );
        result.add(
          LocalOperationDraft(
            kind: OperationKind.assetAttach,
            pageId: after.id,
            objectId: image.id,
            payload: asset.attachPayload,
          ),
        );
        changed['assetId'] = asset.assetId;
        result.add(_set(after.id, image.id, changed));
        result.add(
          LocalOperationDraft(
            kind: OperationKind.assetDetach,
            pageId: after.id,
            objectId: image.id,
            payload: {'assetId': previousId},
          ),
        );
      } else if (changed.isNotEmpty) {
        result.add(_set(after.id, image.id, changed));
      }
    }
    return List<LocalOperationDraft>.unmodifiable(result);
  }

  List<LocalOperationDraft> planCreatePage(
    NotePage page, {
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
  }) {
    final empty = NotePage(
      id: page.id,
      title: page.title,
      isBookmarked: page.isBookmarked,
      inkStrokes: [],
      textBlocks: [],
      imageBlocks: [],
    );
    return [
      LocalOperationDraft(
        kind: OperationKind.pageCreate,
        objectId: page.id,
        payload: {
          'value': {'title': page.title, 'isBookmarked': page.isBookmarked},
        },
      ),
      ...planPageChange(
        before: empty,
        after: page,
        verifiedAssets: verifiedAssets,
      ),
    ];
  }

  LocalOperationDraft planDeletePage(String pageId) => LocalOperationDraft(
    kind: OperationKind.pageDelete,
    objectId: pageId,
    payload: const {},
  );

  /// A move keeps the original object ID and attached asset reference.
  List<LocalOperationDraft> planCrossPageImageMove(
    MoveImageBetweenPagesAction action, {
    required int targetIndex,
  }) {
    if (action.fromPageId == action.toPageId ||
        action.before.id != action.after.id ||
        targetIndex < 0 ||
        targetIndex >= 1000000) {
      throw ArgumentError('Invalid image move.');
    }
    _assertSameImageAsset(action.before, action.after);
    final changed = _diff(
      _imageGeometry(action.before, action.originalIndex),
      _imageGeometry(action.after, targetIndex),
    )..remove('sortIndex');
    return [
      LocalOperationDraft(
        kind: OperationKind.objectMove,
        pageId: action.fromPageId,
        objectId: action.before.id,
        payload: {'toPageId': action.toPageId, 'sortIndex': targetIndex},
      ),
      if (changed.isNotEmpty) _set(action.toPageId, action.before.id, changed),
    ];
  }

  /// Assets are attached before the first atom that references them.
  /// Each text object has its own attachment scope.
  static List<LocalOperationDraft> _attachQuillEmbeds({
    required String pageId,
    required String objectId,
    required String? beforeDelta,
    required String? afterDelta,
    required Map<String, VerifiedEditorAsset> verifiedAssets,
  }) {
    final previous = quillEmbeds(beforeDelta);
    final next = quillEmbeds(afterDelta);
    final drafts = <LocalOperationDraft>[];
    for (final entry in next.entries) {
      if (previous.containsKey(entry.key)) {
        if (previous[entry.key] != entry.value) {
          throw StateError('An existing asset cannot change embed type.');
        }
        continue;
      }
      final asset = verifiedAssets[entry.key];
      if (asset == null || asset.assetId != entry.key) {
        throw StateError('A Quill embed needs a verified asset upload.');
      }
      final isImage = entry.value == 'image';
      if (isImage
          ? !const {
              'image/png',
              'image/jpeg',
              'image/webp',
            }.contains(asset.mediaType)
          : asset.mediaType != 'application/pdf') {
        throw StateError('Quill embed media type does not match the asset.');
      }
      _validateAsset(asset, pageId: pageId, objectId: objectId);
      drafts.add(
        LocalOperationDraft(
          kind: OperationKind.assetAttach,
          pageId: pageId,
          objectId: objectId,
          payload: asset.attachPayload,
        ),
      );
    }
    return drafts;
  }

  /// Removed embeds are detached only after their atoms have been deleted.
  static List<LocalOperationDraft> _detachUnusedQuillEmbeds({
    required String pageId,
    required String objectId,
    required String? beforeDelta,
    required String? afterDelta,
  }) {
    final previous = quillEmbeds(beforeDelta);
    final next = quillEmbeds(afterDelta);
    return [
      for (final id in previous.keys)
        if (!next.containsKey(id))
          LocalOperationDraft(
            kind: OperationKind.assetDetach,
            pageId: pageId,
            objectId: objectId,
            payload: {'assetId': id},
          ),
    ];
  }

  /// Validates canonical image/PDF references and rejects conflicting types.
  static Map<String, String> quillEmbeds(String? deltaJson) {
    if (deltaJson == null) {
      return const {};
    }
    final decoded = jsonDecode(deltaJson);
    if (decoded is! List) {
      throw const FormatException('Invalid Quill delta.');
    }
    final result = <String, String>{};
    for (final entry in decoded) {
      if (entry is! Map || !entry.containsKey('insert')) {
        throw const FormatException('Invalid Quill delta operation.');
      }
      final insert = entry['insert'];
      if (insert is! Map) {
        continue;
      }
      final id = OperationEnvelope.embedAssetId(insert);
      final kind = insert.keys.single as String;
      if (result.containsKey(id) && result[id] != kind) {
        throw const FormatException('Conflicting Quill embed types.');
      }
      result[id] = kind;
    }
    return result;
  }

  static void _validateAsset(
    VerifiedEditorAsset asset, {
    required String pageId,
    required String objectId,
  }) {
    OperationEnvelope.validateV2Payload(
      kind: OperationKind.assetAttach,
      payload: asset.attachPayload,
      documentId: 'editor-bridge',
      pageId: pageId,
      objectId: objectId,
    );
  }

  static void _validateImageAsset(ImageBlock image, VerifiedEditorAsset asset) {
    if (image.imageMime != null && image.imageMime != asset.mediaType) {
      throw StateError('Image/PDF MIME differs from the verified upload.');
    }
    _validateAsset(asset, pageId: 'editor-page', objectId: image.id);
  }

  static Map<String, dynamic> _textGeometry(TextBlock block, int index) => {
    'dx': block.position.dx,
    'dy': block.position.dy,
    'width': block.width,
    'fontSize': block.fontSize,
    'colorValue': block.color.toARGB32(),
    'rotation': block.rotation,
    'sortIndex': index,
  };

  static Map<String, dynamic> _imageGeometry(ImageBlock block, int index) => {
    'dx': block.position.dx,
    'dy': block.position.dy,
    'width': block.width,
    'height': block.height,
    'rotation': block.rotation,
    'cropLeft': block.cropLeft,
    'cropTop': block.cropTop,
    'cropRight': block.cropRight,
    'cropBottom': block.cropBottom,
    'sortIndex': index,
  };

  /// Verified inline bytes define v2 content independently of a local cache.
  /// Path-only legacy images still require an identical path.
  static bool sameImageContent(ImageBlock before, ImageBlock after) =>
      ((before.bytes?.isNotEmpty == true && after.bytes?.isNotEmpty == true) ||
          before.path == after.path) &&
      before.imageMime == after.imageMime &&
      before.imageExt == after.imageExt &&
      _bytes.equals(before.bytes, after.bytes);

  static void _assertSameImageAsset(ImageBlock before, ImageBlock after) {
    if (!sameImageContent(before, after)) {
      throw StateError('Cross-page moves cannot replace image content.');
    }
  }

  static void _checkObjectIds(NotePage page) {
    final seen = <String>{};
    for (final id in [
      ...page.inkStrokes.map((item) => item.id),
      ...page.textBlocks.map((item) => item.id),
      ...page.imageBlocks.map((item) => item.id),
    ]) {
      if (id.isEmpty || !seen.add(id)) {
        throw StateError('Object IDs must be unique across all types.');
      }
    }
  }

  static Map<String, T> _index<T>(List<T> items, String Function(T item) idOf) {
    final indexed = <String, T>{};
    for (final item in items) {
      final id = idOf(item);
      if (id.isEmpty || indexed.containsKey(id)) {
        throw StateError('Missing or duplicate object identity.');
      }
      indexed[id] = item;
    }
    return indexed;
  }

  static Map<String, dynamic> _diff(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) => {
    for (final entry in after.entries)
      if (before[entry.key] != entry.value) entry.key: entry.value,
  };

  static LocalOperationDraft _delete(String pageId, String id) =>
      LocalOperationDraft(
        kind: OperationKind.objectDelete,
        pageId: pageId,
        objectId: id,
        payload: const {},
      );

  static LocalOperationDraft _create(
    String pageId,
    String id,
    Map<String, dynamic> fields,
  ) => LocalOperationDraft(
    kind: OperationKind.objectCreate,
    pageId: pageId,
    objectId: id,
    payload: {'value': fields},
  );

  static LocalOperationDraft _set(
    String pageId,
    String id,
    Map<String, dynamic> fields,
  ) => LocalOperationDraft(
    kind: OperationKind.objectSet,
    pageId: pageId,
    objectId: id,
    payload: {'properties': fields},
  );

  static LocalOperationDraft _textIntent(
    String pageId,
    String id,
    ShareTextIntent intent,
  ) => LocalOperationDraft(
    kind: intent.kind,
    pageId: pageId,
    objectId: id,
    payload: intent.payload,
  );
}
