import 'dart:convert';

import 'package:collection/collection.dart';

import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/operation_store.dart';
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
  }) {
    if (action is MoveImageBetweenPagesAction) {
      throw ArgumentError('Use planCrossPageImageMove for cross-page edits.');
    }
    return planPageChange(
      before: before,
      after: after,
      textAtomsById: textAtomsById,
      verifiedAssets: verifiedAssets,
    );
  }

  List<LocalOperationDraft> planPageChange({
    required NotePage before,
    required NotePage after,
    Map<String, Map<String, dynamic>> textAtomsById = const {},
    Map<String, VerifiedEditorAsset> verifiedAssets = const {},
  }) {
    if (before.id.isEmpty || before.id != after.id) {
      throw ArgumentError('A committed edit must preserve its page ID.');
    }
    final result = <LocalOperationDraft>[];
    final pageProperties = <String, dynamic>{
      if (before.title != after.title) 'title': after.title,
      if (before.isBookmarked != after.isBookmarked)
        'isBookmarked': after.isBookmarked,
    };
    if (pageProperties.isNotEmpty) {
      result.add(LocalOperationDraft(
        kind: OperationKind.pageSet,
        objectId: after.id,
        payload: {'properties': pageProperties},
      ));
    }

    for (final intent in _ink.plan(before: before, after: after)) {
      result.add(LocalOperationDraft(
        kind: intent.kind,
        pageId: intent.pageId,
        objectId: intent.objectId,
        payload: intent.payload,
      ));
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
        _rejectUnattachedEmbeds(block.deltaJson);
        result.add(_create(after.id, block.id, {
          'objectType': 'text',
          ...geometry,
        }));
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
        _rejectUnattachedEmbeds(block.deltaJson);
        final atoms = textAtomsById[block.id];
        if (atoms == null) {
          throw StateError('A text change needs the durable CRDT atom state.');
        }
        for (final intent in _text.plan(
          atoms: atoms,
          newText: block.text,
          changedDeltaJson: block.deltaJson,
        )) {
          result.add(_textIntent(after.id, block.id, intent));
        }
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
        OperationEnvelope.validateV2Payload(
          kind: OperationKind.assetAttach,
          payload: asset.attachPayload,
          documentId: 'editor-bridge',
          pageId: after.id,
          objectId: image.id,
        );
        result.add(_create(after.id, image.id, {
          'objectType': 'image',
          'assetId': asset.assetId,
          ...geometry,
        }));
        result.add(LocalOperationDraft(
          kind: OperationKind.assetAttach,
          pageId: after.id,
          objectId: image.id,
          payload: asset.attachPayload,
        ));
        continue;
      }
      _assertSameImageAsset(old, image);
      final oldIndex = before.imageBlocks.indexWhere((b) => b.id == image.id);
      final changed = _diff(_imageGeometry(old, oldIndex), geometry);
      if (changed.isNotEmpty) {
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
          'value': {
            'title': page.title,
            'isBookmarked': page.isBookmarked,
          },
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
        payload: {
          'toPageId': action.toPageId,
          'sortIndex': targetIndex,
        },
      ),
      if (changed.isNotEmpty)
        _set(action.toPageId, action.before.id, changed),
    ];
  }

  static void _rejectUnattachedEmbeds(String? deltaJson) {
    if (deltaJson == null) return;
    final delta = jsonDecode(deltaJson);
    if (delta is! List) {
      throw const FormatException('Invalid Quill delta.');
    }
    for (final entry in delta) {
      if (entry is Map && entry['insert'] is Map) {
        throw UnsupportedError('Quill embeds need verified asset references.');
      }
    }
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

  static void _assertSameImageAsset(ImageBlock before, ImageBlock after) {
    if (before.path != after.path ||
        before.imageMime != after.imageMime ||
        before.imageExt != after.imageExt ||
        !_bytes.equals(before.bytes, after.bytes)) {
      throw StateError('Changed image bytes require verified asset replacement.');
    }
  }

  static Map<String, T> _index<T>(
    List<T> items,
    String Function(T item) idOf,
  ) {
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
