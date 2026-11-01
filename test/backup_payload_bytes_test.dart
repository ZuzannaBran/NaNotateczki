import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/backup/backup_payload_bytes.dart';

void main() {
  test('preserves numbers, Unicode and escaped delimiters exactly', () {
    const payload =
        r'{"number":1.0000,"tiny":1e-07,"text":"żółć } , \" payload","list":[{},1]}';
    final bytes = Uint8List.fromList(
      utf8.encode(
        '{"other":{"payload":"ignored"},"payload":$payload ,"tail":true}',
      ),
    );
    jsonDecode(utf8.decode(bytes));
    expect(utf8.decode(backupPayloadBytes(bytes)), payload);
  });

  test('escaped top-level key and duplicate keys follow JSON decoding', () {
    final bytes = Uint8List.fromList(
      utf8.encode(r'{"payload":{},"payl\u006fad":{"number":1.000}}'),
    );
    expect(utf8.decode(backupPayloadBytes(bytes)), '{"number":1.000}');
  });

  test('does not mistake a nested payload for the backup payload', () {
    final bytes = Uint8List.fromList(utf8.encode('{"other":{"payload":{}}}'));
    expect(() => backupPayloadBytes(bytes), throwsFormatException);
  });
}
