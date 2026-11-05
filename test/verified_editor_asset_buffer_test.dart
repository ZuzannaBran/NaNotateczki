import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/verified_editor_asset_buffer.dart';

void main() {
  const firstId = 'verified-test-asset';
  final contents = Uint8List.fromList([137, 80, 78, 71, 1, 2]);
  final sha = sha256.convert(contents).toString();
  final receipt = <String, dynamic>{
    'assetId': firstId,
    'sha256': sha,
    'sizeBytes': contents.length,
    'mediaType': 'image/png',
  };

  test('stages and copies checksummed bytes, not caller-owned memory', () {
    final buffer = VerifiedEditorAssetBuffer();
    final input = Uint8List.fromList(contents);
    buffer.stage(receipt: receipt, bytes: input);
    input[0] = 0;
    expect(buffer.requireBytes(receipt), orderedEquals(contents));
    final returned = buffer.requireBytes(receipt);
    returned[0] = 0;
    expect(buffer.requireBytes(receipt), orderedEquals(contents));
    buffer.clear();
    expect(() => buffer.requireBytes(receipt), throwsStateError);
  });

  test('rejects corrupt upload/download acknowledgements', () {
    final buffer = VerifiedEditorAssetBuffer();
    expect(
      () => buffer.stage(
        receipt: receipt,
        bytes: Uint8List.fromList([0, 1, 2]),
      ),
      throwsFormatException,
    );
    expect(
      () => buffer.stage(
        receipt: {...receipt, 'sizeBytes': contents.length + 1},
        bytes: contents,
      ),
      throwsFormatException,
    );
    expect(
      () => buffer.stage(
        receipt: {...receipt, 'mediaType': 'application/x-unknown'},
        bytes: contents,
      ),
      throwsFormatException,
    );
    expect(() => buffer.requireBytes(receipt), throwsStateError);
  });

  test('an asset ID cannot silently switch to a different digest', () {
    final buffer = VerifiedEditorAssetBuffer()
      ..stage(receipt: receipt, bytes: contents);
    final replacement = Uint8List.fromList([7, 8, 9, 10]);
    final altered = {
      ...receipt,
      'sha256': sha256.convert(replacement).toString(),
      'sizeBytes': replacement.length,
    };
    expect(
      () => buffer.stage(receipt: altered, bytes: replacement),
      throwsStateError,
    );
    expect(buffer.requireBytes(receipt), orderedEquals(contents));
  });
}
