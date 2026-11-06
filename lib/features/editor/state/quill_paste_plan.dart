import 'dart:convert';
import 'dart:typed_data';

import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/share_text_edit_adapter.dart';
import '../../../data/sync/verified_editor_asset_buffer.dart';

/// A validated paste; no assets are registered until the complete input passes.
class QuillPastePlan {
  QuillPastePlan._(
    this._operations,
    this._imports,
    this.existingAssets,
    this.importedByteLength,
    this.characterCount,
  );

  static const maximumBytes = 64 * 1024 * 1024;
  final List<Map<String, dynamic>> _operations;
  final List<_InlineImport> _imports;
  final Map<String, String> existingAssets;
  final int importedByteLength;
  final int characterCount;
  int get embedCount => _operations.where((op) => op['insert'] is Map).length;

  static Future<Uint8List> readMediaBytes(
    Stream<Uint8List> stream, {
    int byteLimit = maximumBytes,
  }) async {
    if (byteLimit < 1 || byteLimit > maximumBytes) {
      throw ArgumentError('Invalid paste byte limit.');
    }
    final bytes = BytesBuilder();
    await for (final chunk in stream) {
      if (chunk.length > byteLimit - bytes.length) {
        throw const FormatException('Inline media exceeds the size limit.');
      }
      bytes.add(chunk);
    }
    if (bytes.isEmpty) {
      throw const FormatException('Inline media is empty.');
    }
    return bytes.takeBytes();
  }

  factory QuillPastePlan.fromMediaBytes(
    Uint8List bytes, {
    int byteLimit = maximumBytes,
  }) {
    if (byteLimit < 1 || byteLimit > maximumBytes) {
      throw ArgumentError('Invalid paste byte limit.');
    }
    if (bytes.isEmpty || bytes.length > byteLimit) {
      throw const FormatException('Invalid inline file size.');
    }
    final mime = VerifiedEditorAssetBuffer.inferMediaType(bytes);
    final type = mime == 'application/pdf' ? 'pdf' : 'image';
    return QuillPastePlan._(
      [
        {
          'insert': {type: 'asset:paste-0'},
        },
      ],
      [
        _InlineImport(type, Uint8List.fromList(bytes), [0], 0),
      ],
      const {},
      bytes.length,
      1,
    );
  }

  factory QuillPastePlan.fromDelta(
    List<dynamic> delta, {
    int byteLimit = maximumBytes,
  }) {
    if (byteLimit < 1 || byteLimit > maximumBytes) {
      throw ArgumentError('Invalid paste byte limit.');
    }
    if (delta.length > ShareTextEditAdapter.maxCodePoints) {
      throw const FormatException('Paste exceeds the text operation budget.');
    }
    final operations = <Map<String, dynamic>>[];
    final imports = <_InlineImport>[];
    final bySource = <String, _InlineImport>{};
    final existing = <String, String>{};
    var byteLength = 0;
    var characters = 0;
    for (final raw in delta) {
      if (raw is! Map ||
          !raw.containsKey('insert') ||
          raw.keys.any((key) => key != 'insert' && key != 'attributes')) {
        throw const FormatException('Paste needs insert-only Delta.');
      }
      final operation = Map<String, dynamic>.from(raw);
      final insert = operation['insert'];
      if (insert is String) {
        if (insert.length > ShareTextEditAdapter.maxCodePoints * 2 ||
            insert.contains('\uFFFC')) {
          throw const FormatException('Invalid plain text in paste.');
        }
        characters += insert.runes.length;
      } else if (insert is Map &&
          insert.length == 1 &&
          (insert.containsKey('image') || insert.containsKey('pdf')) &&
          insert.values.single is String) {
        characters++;
        final type = insert.keys.single as String;
        final source = insert.values.single as String;
        if (source.startsWith('asset:')) {
          final id = OperationEnvelope.embedAssetId(insert);
          if (existing.containsKey(id) && existing[id] != type) {
            throw const FormatException('Conflicting pasted asset types.');
          }
          existing[id] = type;
          operation['insert'] = Map<String, dynamic>.from(insert);
        } else {
          var asset = bySource[source];
          if (asset == null) {
            if (source.length > byteLimit * 3 + 256) {
              throw const FormatException('Pasted media is too large.');
            }
            final uri = Uri.parse(source);
            final data = uri.data;
            if (data == null || uri.scheme != 'data') {
              throw const FormatException(
                'Paste media must contain local bytes.',
              );
            }
            final mime = data.mimeType.toLowerCase();
            if (type == 'pdf'
                ? mime != 'application/pdf'
                : !const {
                    'image/png',
                    'image/jpeg',
                    'image/webp',
                  }.contains(mime)) {
              throw const FormatException('Pasted media type is unsupported.');
            }
            final bytes = data.contentAsBytes();
            byteLength += bytes.length;
            if (bytes.isEmpty ||
                byteLength > byteLimit ||
                VerifiedEditorAssetBuffer.inferMediaType(bytes) != mime) {
              throw const FormatException(
                'Pasted bytes differ from their type or size.',
              );
            }
            asset = _InlineImport(type, bytes, [], imports.length);
            bySource[source] = asset;
            imports.add(asset);
          } else if (asset.type != type) {
            throw const FormatException('Conflicting pasted media types.');
          }
          asset.operationIndexes.add(operations.length);
          operation['insert'] = {type: 'asset:paste-${asset.index}'};
        }
      } else {
        throw const FormatException('Unsupported paste embed.');
      }
      if (characters > ShareTextEditAdapter.maxCodePoints) {
        throw const FormatException('Paste exceeds the text operation budget.');
      }
      operations.add(operation);
    }
    try {
      final json = jsonEncode(operations);
      ShareTextEditAdapter.validateDelta(json);
      return QuillPastePlan._(
        (jsonDecode(json) as List)
            .map((op) => Map<String, dynamic>.from(op as Map))
            .toList(),
        imports,
        Map<String, String>.unmodifiable(existing),
        byteLength,
        characters,
      );
    } on JsonUnsupportedObjectError {
      throw const FormatException('Invalid paste attributes.');
    }
  }

  /// Called only after scope checks and async lifecycle checks have succeeded.
  List<Map<String, dynamic>> materialize(
    String Function(Uint8List bytes, String embedType) prepare,
  ) {
    final result = (jsonDecode(jsonEncode(_operations)) as List)
        .map((op) => Map<String, dynamic>.from(op as Map))
        .toList();
    for (final asset in _imports) {
      final reference = prepare(asset.bytes, asset.type);
      OperationEnvelope.embedAssetId({asset.type: reference});
      for (final index in asset.operationIndexes) {
        result[index]['insert'] = {asset.type: reference};
      }
    }
    return result;
  }
}

class _InlineImport {
  _InlineImport(this.type, this.bytes, this.operationIndexes, this.index);
  final String type;
  final Uint8List bytes;
  final List<int> operationIndexes;
  final int index;
}
