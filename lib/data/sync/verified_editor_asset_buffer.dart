import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'operation_protocol.dart';

/// In-memory buffer of locally checksum-verified media.
///
/// Staging local bytes does not imply that a server has received them.
/// The outbox uploads them before transmitting their asset.attach operation.
/// The SQLite projector refuses references for absent or mismatched bytes.
/// This buffer is deliberately not a durable cache; committed image bytes
/// are copied to SQLite in the same transaction as asset.attach.
class VerifiedEditorAssetBuffer {
  final Map<String, _VerifiedBytes> _items = {};

  void stage({
    required Map<String, dynamic> receipt,
    required Uint8List bytes,
  }) {
    OperationEnvelope.validateV2Payload(
      kind: OperationKind.assetAttach,
      payload: receipt,
      documentId: 'verified-asset-buffer',
      pageId: 'verified-page',
      objectId: 'verified-object',
    );
    final digest = receipt['sha256'] as String;
    final size = receipt['sizeBytes'] as int;
    final mime = receipt['mediaType'] as String;
    final id = receipt['assetId'] as String;
    if (bytes.length != size ||
        crypto.sha256.convert(bytes).toString() != digest) {
      throw const FormatException('Asset contents differ from receipt.');
    }
    final existing = _items[id];
    if (existing != null &&
        (existing.digest != digest || existing.mime != mime)) {
      throw StateError('An asset ID cannot change its verified contents.');
    }
    _items[id] = _VerifiedBytes(
      digest: digest,
      mime: mime,
      bytes: Uint8List.fromList(bytes),
    );
  }

  Uint8List requireBytes(Map<String, dynamic> receipt) {
    final id = receipt['assetId'] as String;
    final expected = receipt['sha256'] as String;
    final size = receipt['sizeBytes'] as int;
    final mime = receipt['mediaType'] as String;
    final item = _items[id];
    if (item == null ||
        item.digest != expected ||
        item.mime != mime ||
        item.bytes.length != size ||
        crypto.sha256.convert(item.bytes).toString() != expected) {
      throw StateError('The verified asset bytes must be staged first.');
    }
    return Uint8List.fromList(item.bytes);
  }

  void clear() => _items.clear();
}

class _VerifiedBytes {
  const _VerifiedBytes({
    required this.digest,
    required this.mime,
    required this.bytes,
  });

  final String digest;
  final String mime;
  final Uint8List bytes;
}
