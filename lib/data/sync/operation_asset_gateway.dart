import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'api_client.dart';
import 'verified_editor_asset_buffer.dart';

/// Verified bytes are uploaded before an asset.attach operation is enqueued.
///
/// The returned digest is content-addressed; a server ACK without matching
/// checksum, length and MIME is never treated as a durable upload.
class OperationAssetGateway {
  OperationAssetGateway(this.apiClient, {this.shareId, this.guestTicket}) {
    if ((shareId == null) != (guestTicket == null)) {
      throw ArgumentError('Share assets require a scoped guest ticket.');
    }
    if (guestTicket != null &&
        (guestTicket!.length < 40 ||
            guestTicket!.length > 256 ||
            RegExp(r'[\x00-\x20\x7f]').hasMatch(guestTicket!))) {
      throw ArgumentError('Invalid guest ticket.');
    }
  }

  static const maximumAssetBytes = 64 * 1024 * 1024;
  static const supportedMimeTypes = <String>{
    'image/png',
    'image/jpeg',
    'image/webp',
    'application/pdf',
  };

  final ApiClient apiClient;
  final String? shareId;
  final String? guestTicket;

  Map<String, String>? get _shareHeaders => shareId == null
      ? null
      : {'X-Share-Id': shareId!, 'Authorization': 'Bearer $guestTicket'};

  /// Uploads validated bytes and returns a safe payload for asset.attach.
  Future<Map<String, dynamic>> upload({
    required String assetId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    if (assetId.isEmpty ||
        assetId.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(assetId) ||
        bytes.isEmpty ||
        bytes.length > maximumAssetBytes ||
        !supportedMimeTypes.contains(mediaType)) {
      throw ArgumentError('Invalid asset metadata or size.');
    }
    final digest = crypto.sha256.convert(bytes).toString();
    final response = await apiClient.request(
      'PUT',
      '/v2/assets/$digest',
      body: bytes,
      authenticated: guestTicket == null,
      headers: {'Content-Type': mediaType, ...?_shareHeaders},
    );
    final decoded = response.decodeJson();
    if (decoded is! Map ||
        decoded['sha256'] != digest ||
        decoded['sizeBytes'] != bytes.length ||
        decoded['mediaType'] != mediaType) {
      throw const FormatException('Unverified asset upload acknowledgement.');
    }
    return {
      'assetId': assetId,
      'sha256': digest,
      'sizeBytes': bytes.length,
      'mediaType': mediaType,
    };
  }

  /// Only authenticated upload acknowledgements can stage local bytes.
  Future<Map<String, dynamic>> uploadAndStage({
    required String assetId,
    required List<int> bytes,
    required String mediaType,
    required VerifiedEditorAssetBuffer buffer,
  }) async {
    final receipt = await upload(
      assetId: assetId,
      bytes: bytes,
      mediaType: mediaType,
    );
    buffer.stage(
      receipt: receipt,
      bytes: Uint8List.fromList(bytes),
    );
    return receipt;
  }

  /// Checks remote bytes before making them available to the SQLite reducer.
  Future<void> downloadAndStage({
    required Map<String, dynamic> receipt,
    required VerifiedEditorAssetBuffer buffer,
  }) async {
    final digest = receipt['sha256'];
    final size = receipt['sizeBytes'];
    if (digest is! String || size is! int) {
      throw const FormatException('Invalid asset download receipt.');
    }
    final bytes = await download(sha256: digest, sizeBytes: size);
    buffer.stage(receipt: receipt, bytes: bytes);
  }

  /// Downloads verified bytes; never exposes corrupt or partial responses.
  Future<Uint8List> download({
    required String sha256,
    required int sizeBytes,
  }) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        sizeBytes <= 0 ||
        sizeBytes > maximumAssetBytes) {
      throw ArgumentError('Invalid asset checksum or length.');
    }
    final response = await apiClient.request(
      'GET',
      '/v2/assets/$sha256',
      authenticated: guestTicket == null,
      headers: _shareHeaders,
      maxResponseBytes: maximumAssetBytes,
    );
    final data = response.bodyBytes;
    if (data.length != sizeBytes ||
        crypto.sha256.convert(data).toString() != sha256) {
      throw const FormatException('Asset checksum or length mismatch.');
    }
    return data;
  }
}
