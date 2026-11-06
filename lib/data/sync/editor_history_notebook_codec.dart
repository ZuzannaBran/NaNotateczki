import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';

import '../../features/notebook/domain/image_block.dart';
import '../../features/notebook/domain/ink_stroke.dart';
import '../../features/notebook/domain/note_page.dart';
import '../../features/notebook/domain/notebook.dart';
import '../../features/notebook/domain/notebook_kind.dart';
import '../../features/notebook/domain/text_block.dart';
import 'editor_history_checkpoint.dart';
import 'editor_sqlite_projector.dart';
import 'operation_protocol.dart';
import 'operation_text_sequence.dart';
import 'share_ink_edit_adapter.dart';
import 'share_text_edit_adapter.dart';
import 'verified_editor_asset_buffer.dart';

/// Local Undo boundaries contain metadata and durable asset receipts only.
/// No file paths, inline bytes, network access or legacy snapshot restore.
class EditorHistoryNotebookCodec {
  EditorHistoryNotebookCodec(this.projector);

  final EditorSqliteProjector projector;
  static const _equal = DeepCollectionEquality();

  /// Reidentifies already captured metadata for an inverse without hydrating
  /// all historical BLOBs. Asset IDs, Delta content and document scope stay put.
  Map<String, dynamic> remapIdentities(
    Map<String, dynamic> value, {
    required String documentId,
    Map<String, String> pageIds = const {},
    Map<String, String> objectIds = const {},
  }) {
    final root = jsonDecode(_budget(value)) as Map<String, dynamic>;
    _notebook(root, documentId, {});
    for (final mapping in [pageIds, objectIds]) {
      final targets = <String>{};
      for (final entry in mapping.entries) {
        _id(entry.key);
        if (!targets.add(_id(entry.value))) {
          throw const FormatException('Ambiguous history identity remapping.');
        }
      }
    }
    for (final rawPage in root['pages'] as List) {
      final page = rawPage as Map;
      page['id'] = pageIds[page['id']] ?? page['id'];
      for (final layer in ['images', 'texts', 'ink']) {
        for (final rawObject in page[layer] as List) {
          final object = rawObject as Map;
          object['id'] = objectIds[object['id']] ?? object['id'];
        }
      }
    }
    _notebook(root, documentId, {});
    _budget(root);
    return root;
  }

  Future<Map<String, Map<String, dynamic>>> _receipts(String documentId) async {
    final rows = await projector.database
        .customSelect(
          'SELECT envelope_json FROM operations '
          'WHERE document_id = ? AND kind = ? ORDER BY rowid LIMIT 50001',
          variables: [
            Variable<String>(documentId),
            const Variable<String>('asset.attach'),
          ],
        )
        .get();
    if (rows.length > 50000) {
      throw StateError('Asset history requires a checkpoint.');
    }
    final result = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final operation = OperationEnvelope.fromJson(
        _map(jsonDecode(row.read<String>('envelope_json'))),
      );
      operation.validateForV2Projection();
      if (operation.documentId != documentId ||
          operation.kind != OperationKind.assetAttach) {
        throw const FormatException('History asset journal scope mismatch.');
      }
      final receipt = operation.payload;
      final id = receipt['assetId'] as String;
      if (result.containsKey(id) && !_equal.equals(result[id], receipt)) {
        throw const FormatException('History asset has conflicting receipts.');
      }
      result[id] = Map<String, dynamic>.from(receipt);
    }
    return result;
  }

  Future<Uint8List> _bytes(Map<String, dynamic> receipt) async {
    final bytes = await projector.verifiedUploadBytes(receipt);
    if (VerifiedEditorAssetBuffer.inferMediaType(bytes) !=
        receipt['mediaType']) {
      throw const FormatException('History asset signature mismatch.');
    }
    return bytes;
  }

  /// Images must already have frozen bytes and a committed receipt in this
  /// document. Path-only imports must be materialized before this boundary.
  Future<Map<String, dynamic>> encode(Notebook notebook) async {
    final assets = <String, Map<String, dynamic>>{};
    final pendingImages =
        <
          ({Map<String, dynamic> value, String digest, int size, String mime})
        >[];
    final embeds = <String, String>{};
    // Freeze metadata and content fingerprints before the first SQLite await.
    // A later optimistic gesture must not change this history boundary.
    final pages = <Map<String, dynamic>>[];
    for (final page in notebook.pages) {
      final images = <Map<String, dynamic>>[];
      for (final image in page.imageBlocks) {
        final bytes = image.bytes;
        if (bytes == null || bytes.isEmpty) {
          throw const FormatException('History image requires frozen bytes.');
        }
        final digest = crypto.sha256.convert(bytes).toString();
        final mime = VerifiedEditorAssetBuffer.inferMediaType(bytes);
        if (image.imageMime != null && image.imageMime != mime) {
          throw const FormatException('History image MIME mismatch.');
        }
        final value = <String, dynamic>{
          'id': image.id,
          'assetId': '',
          'ocrText': image.ocrText,
          'dx': image.position.dx,
          'dy': image.position.dy,
          'width': image.width,
          'height': image.height,
          'rotation': image.rotation,
          'cropLeft': image.cropLeft,
          'cropTop': image.cropTop,
          'cropRight': image.cropRight,
          'cropBottom': image.cropBottom,
        };
        images.add(value);
        pendingImages.add((
          value: value,
          digest: digest,
          size: bytes.length,
          mime: mime,
        ));
      }
      for (final block in page.textBlocks) {
        for (final embed in _embeds(block.text, block.deltaJson).entries) {
          if (embeds.containsKey(embed.key) &&
              embeds[embed.key] != embed.value) {
            throw const FormatException('Conflicting history embed types.');
          }
          embeds[embed.key] = embed.value;
        }
      }
      pages.add({
        'id': page.id,
        'title': page.title,
        'isBookmarked': page.isBookmarked,
        'images': images,
        'texts': [
          for (final block in page.textBlocks)
            {
              'id': block.id,
              'text': block.text,
              'deltaJson': block.deltaJson,
              'dx': block.position.dx,
              'dy': block.position.dy,
              'fontSize': block.fontSize,
              'color': block.color.toARGB32(),
              'width': block.width,
              'rotation': block.rotation,
            },
        ],
        'ink': [
          for (final stroke in page.inkStrokes)
            {
              'id': stroke.id,
              'color': stroke.color.toARGB32(),
              'width': stroke.width,
              'tool': stroke.tool.index,
              'points': [
                for (final point in stroke.points)
                  [point.dx, point.dy, point.pressure],
              ],
            },
        ],
      });
    }
    final result = <String, dynamic>{
      'version': 1,
      'uid': notebook.uid,
      'title': notebook.title,
      'kind': notebook.kind.name,
      'folder': notebook.folder,
      'createdAt': notebook.createdAt.toUtc().toIso8601String(),
      'updatedAt': notebook.updatedAt.toUtc().toIso8601String(),
      'pages': pages,
      'assets': assets,
    };
    _budget(result);
    final receipts = await _receipts(notebook.uid);
    final verified = <String>{};
    Future<String> use(String id) async {
      final receipt = receipts[id];
      if (receipt == null) {
        throw const FormatException('History asset has no document receipt.');
      }
      if (verified.add(id)) {
        await _bytes(receipt);
      }
      assets[id] = receipt;
      return id;
    }

    for (final image in pendingImages) {
      // Keep the earliest durable alias so later imports of identical bytes
      // cannot change an already captured boundary's content-addressed state.
      final matches = receipts.entries.where(
        (entry) =>
            entry.value['sha256'] == image.digest &&
            entry.value['sizeBytes'] == image.size &&
            entry.value['mediaType'] == image.mime,
      );
      if (matches.isEmpty) {
        throw const FormatException('History image is not durably verified.');
      }
      image.value['assetId'] = await use(matches.first.key);
    }
    for (final embed in embeds.entries) {
      await use(embed.key);
      _embedType(embed.value, receipts[embed.key]!);
    }
    _budget(result);
    // Run the same structural validation as recovery, without copying BLOBs.
    _notebook(result, notebook.uid, {});
    return result;
  }

  /// Rechecks receipts and durable bytes even after all visible owners were
  /// deleted. Recovery never reads paths, downloads files or mutates SQLite.
  Future<Notebook> decode(
    Map<String, dynamic> value, {
    required String documentId,
  }) async {
    final root = jsonDecode(_budget(value)) as Map<String, dynamic>;
    _notebook(root, documentId, {});
    final assets = _map(root['assets']);
    final receipts = await _receipts(documentId);
    final bytes = <String, Uint8List>{};
    final verified = <String, Uint8List>{};
    for (final entry in assets.entries) {
      final receipt = _map(entry.value);
      if (!_equal.equals(receipts[entry.key], receipt) ||
          receipt['assetId'] != entry.key) {
        throw const FormatException('History asset receipt scope mismatch.');
      }
      final key = jsonEncode([
        receipt['sha256'],
        receipt['sizeBytes'],
        receipt['mediaType'],
      ]);
      bytes[entry.key] = verified[key] ??= await _bytes(receipt);
    }
    return _notebook(root, documentId, bytes);
  }

  static Notebook _notebook(
    Map<String, dynamic> root,
    String documentId,
    Map<String, Uint8List> bytes,
  ) {
    _keys(root, {
      'version',
      'uid',
      'title',
      'kind',
      'folder',
      'createdAt',
      'updatedAt',
      'pages',
      'assets',
    });
    if (root['version'] is! int ||
        root['version'] != 1 ||
        _id(root['uid']) != documentId) {
      throw const FormatException('Unsupported history notebook or scope.');
    }
    final kind = switch (root['kind']) {
      'notebook' => NotebookKind.notebook,
      'board' => NotebookKind.board,
      _ => throw const FormatException('Unsupported history notebook kind.'),
    };
    final assets = _map(root['assets']);
    final usedAssets = <String>{};
    final ids = <String>{documentId};
    String identity(Object? value) {
      final id = _id(value);
      if (!ids.add(id)) {
        throw const FormatException('Duplicate history object identity.');
      }
      return id;
    }

    Map<String, dynamic> asset(Object? id) {
      final key = _id(id);
      final receipt = _map(assets[key]);
      _keys(receipt, {'assetId', 'sha256', 'sizeBytes', 'mediaType'});
      if (receipt['assetId'] != key) {
        throw const FormatException('History asset identity mismatch.');
      }
      usedAssets.add(key);
      return receipt;
    }

    final pages = <NotePage>[];
    for (final raw in _list(root['pages'])) {
      final page = _map(raw);
      _keys(page, {'id', 'title', 'isBookmarked', 'images', 'texts', 'ink'});
      final pageId = identity(page['id']);
      if (page['isBookmarked'] is! bool) {
        throw const FormatException('Invalid history page bookmark.');
      }
      final texts = <TextBlock>[];
      for (final raw in _list(page['texts'])) {
        final text = _map(raw);
        _keys(text, {
          'id',
          'text',
          'deltaJson',
          'dx',
          'dy',
          'fontSize',
          'color',
          'width',
          'rotation',
        });
        final plain = _string(text['text']);
        final delta = text['deltaJson'] == null
            ? null
            : _string(text['deltaJson']);
        for (final embed in _embeds(plain, delta).entries) {
          _embedType(embed.value, asset(embed.key));
        }
        texts.add(
          TextBlock(
            id: identity(text['id']),
            text: plain,
            deltaJson: delta,
            position: Offset(_number(text['dx']), _number(text['dy'])),
            fontSize: _positive(text['fontSize']),
            color: _color(text['color']),
            width: _positive(text['width']),
            rotation: _number(text['rotation']),
          ),
        );
      }
      final images = <ImageBlock>[];
      for (final raw in _list(page['images'])) {
        final image = _map(raw);
        _keys(image, {
          'id',
          'assetId',
          'ocrText',
          'dx',
          'dy',
          'width',
          'height',
          'rotation',
          'cropLeft',
          'cropTop',
          'cropRight',
          'cropBottom',
        });
        final receipt = asset(image['assetId']);
        final left = _number(image['cropLeft']);
        final top = _number(image['cropTop']);
        final right = _number(image['cropRight']);
        final bottom = _number(image['cropBottom']);
        if (left < 0 ||
            top < 0 ||
            right > 1 ||
            bottom > 1 ||
            left >= right ||
            top >= bottom) {
          throw const FormatException('Invalid history image crop.');
        }
        final mime = _string(receipt['mediaType']);
        final extension = switch (mime) {
          'image/png' => 'png',
          'image/jpeg' => 'jpg',
          'image/webp' => 'webp',
          'application/pdf' => 'pdf',
          _ => throw const FormatException('Unsupported history media type.'),
        };
        images.add(
          ImageBlock(
            id: identity(image['id']),
            path: '',
            ocrText: _string(image['ocrText']),
            bytes: bytes[image['assetId']] == null
                ? null
                : Uint8List.fromList(bytes[image['assetId']]!),
            imageExt: extension,
            imageMime: mime,
            position: Offset(_number(image['dx']), _number(image['dy'])),
            width: _positive(image['width']),
            height: _positive(image['height']),
            rotation: _number(image['rotation']),
            cropLeft: left,
            cropTop: top,
            cropRight: right,
            cropBottom: bottom,
          ),
        );
      }
      final ink = <InkStroke>[];
      for (final raw in _list(page['ink'])) {
        final stroke = _map(raw);
        _keys(stroke, {'id', 'color', 'width', 'tool', 'points'});
        ink.add(
          ShareInkEditAdapter().decode(identity(stroke['id']), {
            'type': OperationKind.strokeCreate.wireName,
            'properties': {
              'colorValue': stroke['color'],
              'width': stroke['width'],
              'toolIndex': stroke['tool'],
              'points': stroke['points'],
            },
          }),
        );
      }
      pages.add(
        NotePage(
          id: pageId,
          title: _string(page['title']),
          isBookmarked: page['isBookmarked'] as bool,
          textBlocks: texts,
          imageBlocks: images,
          inkStrokes: ink,
        ),
      );
    }
    if (pages.isEmpty || usedAssets.length != assets.length) {
      throw const FormatException('Empty history notebook or unused assets.');
    }
    return Notebook(
      uid: documentId,
      title: _string(root['title']),
      kind: kind,
      folder: _string(root['folder']),
      createdAt: _date(root['createdAt']),
      updatedAt: _date(root['updatedAt']),
      pages: pages,
    );
  }

  static Map<String, String> _embeds(String text, String? delta) {
    if (text.runes.length > ShareTextEditAdapter.maxCodePoints) {
      throw const FormatException('History text exceeds its budget.');
    }
    if (delta == null) {
      return {};
    }
    ShareTextEditAdapter.validateDelta(delta);
    final plain = StringBuffer();
    final result = <String, String>{};
    for (final raw in jsonDecode(delta) as List) {
      final insert = (raw as Map)['insert'];
      if (insert is String) {
        plain.write(insert);
      } else {
        final embed = _map(insert);
        final id = OperationEnvelope.embedAssetId(embed);
        final type = embed.keys.single;
        if (result.containsKey(id) && result[id] != type) {
          throw const FormatException('Conflicting history embed types.');
        }
        result[id] = type;
        plain.write('\uFFFC');
      }
    }
    final actual = plain.toString();
    if (actual != text &&
        !(actual.endsWith('\n') &&
            OperationTextSequence.withoutQuillTerminalNewline(actual) ==
                text)) {
      throw const FormatException('History Delta differs from its text.');
    }
    return result;
  }

  static void _embedType(String type, Map<String, dynamic> receipt) {
    if (type == 'pdf'
        ? receipt['mediaType'] != 'application/pdf'
        : type != 'image' ||
              !{
                'image/png',
                'image/jpeg',
                'image/webp',
              }.contains(receipt['mediaType'])) {
      throw const FormatException('History embed MIME mismatch.');
    }
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid history object.');
    }
    return Map<String, dynamic>.from(value);
  }

  static List _list(Object? value) {
    if (value is! List) {
      throw const FormatException('Invalid history list.');
    }
    return value;
  }

  static void _keys(Map value, Set<String> keys) {
    if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
      throw const FormatException('Unsupported history fields.');
    }
  }

  static String _string(Object? value) {
    if (value is! String) {
      throw const FormatException('Invalid history string.');
    }
    return value;
  }

  static String _id(Object? value) {
    final id = _string(value);
    if (id.isEmpty ||
        id.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(id)) {
      throw const FormatException('Invalid history identity.');
    }
    return id;
  }

  static double _number(Object? value) {
    if (value is! num || !value.isFinite) {
      throw const FormatException('Invalid history number.');
    }
    return value.toDouble();
  }

  static double _positive(Object? value) {
    final number = _number(value);
    if (number <= 0) {
      throw const FormatException('Invalid history dimension.');
    }
    return number;
  }

  static Color _color(Object? value) {
    if (value is! int || value < 0 || value > 0xFFFFFFFF) {
      throw const FormatException('Invalid history color.');
    }
    return Color(value);
  }

  static DateTime _date(Object? value) {
    final text = _string(value);
    final date = DateTime.tryParse(text);
    if (date == null || date.toUtc().toIso8601String() != text) {
      throw const FormatException('Invalid history date.');
    }
    return date;
  }

  static String _budget(Map<String, dynamic> value) {
    try {
      final json = jsonEncode(value);
      if (utf8.encode(json).length > EditorHistoryCheckpoint.maximumBytes) {
        throw const EditorHistoryBudgetExceeded(
          'History notebook exceeds its byte budget.',
        );
      }
      return json;
    } on JsonUnsupportedObjectError {
      throw const FormatException('History notebook is not JSON.');
    }
  }
}
