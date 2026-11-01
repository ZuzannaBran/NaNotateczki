import 'dart:convert';
import 'dart:typed_data';

/// Returns the payload's original UTF-8 bytes from an already validated JSON.
/// Numeric spelling must survive hashing across native Dart and JavaScript.
Uint8List backupPayloadBytes(Uint8List bytes) {
  var offset = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    offset = 3;
  }
  offset = _skipSpace(bytes, offset);
  if (offset >= bytes.length || bytes[offset] != 0x7b) {
    throw const FormatException('Backup envelope must be an object.');
  }
  offset++;
  Uint8List? payload;
  while (offset < bytes.length) {
    offset = _skipSpace(bytes, offset);
    if (offset >= bytes.length || bytes[offset] == 0x7d) {
      break;
    }
    if (bytes[offset] != 0x22) {
      throw const FormatException('Invalid backup envelope key.');
    }
    final start = offset++;
    while (offset < bytes.length) {
      if (bytes[offset] == 0x5c) {
        offset += 2;
      } else if (bytes[offset++] == 0x22) {
        break;
      }
    }
    final key = jsonDecode(utf8.decode(bytes.sublist(start, offset)));
    offset = _skipSpace(bytes, offset);
    if (offset >= bytes.length || bytes[offset++] != 0x3a) {
      throw const FormatException('Invalid backup envelope separator.');
    }
    offset = _skipSpace(bytes, offset);
    final valueStart = offset;
    var depth = 0;
    var quoted = false;
    while (offset < bytes.length) {
      final byte = bytes[offset];
      if (quoted) {
        if (byte == 0x5c) {
          offset += 2;
          continue;
        }
        if (byte == 0x22) {
          quoted = false;
        }
      } else if (byte == 0x22) {
        quoted = true;
      } else if (byte == 0x7b || byte == 0x5b) {
        depth++;
      } else if (byte == 0x7d || byte == 0x5d) {
        if (depth == 0) {
          break;
        }
        depth--;
      } else if (byte == 0x2c && depth == 0) {
        break;
      }
      offset++;
    }
    if (key == 'payload') {
      var end = offset;
      while (end > valueStart && _isSpace(bytes[end - 1])) {
        end--;
      }
      // Match jsonDecode's last-key-wins behavior for legacy envelopes.
      payload = Uint8List.sublistView(bytes, valueStart, end);
    }
    if (offset < bytes.length && bytes[offset] == 0x2c) {
      offset++;
    } else if (offset < bytes.length && bytes[offset] == 0x7d) {
      break;
    } else {
      throw const FormatException('Invalid backup envelope delimiter.');
    }
  }
  if (payload == null) {
    throw const FormatException('Backup payload is missing.');
  }
  return payload;
}

int _skipSpace(Uint8List bytes, int offset) {
  while (offset < bytes.length && _isSpace(bytes[offset])) {
    offset++;
  }
  return offset;
}

bool _isSpace(int byte) =>
    byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d;
