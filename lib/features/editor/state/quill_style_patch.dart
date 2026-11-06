import 'dart:convert';

/// Applies only requested style fields while retaining insert/embed data.
String patchQuillStyle(
  String source, {
  required Map<String, dynamic> inlineChanges,
  required Map<String, dynamic> paragraphChanges,
}) {
  final decoded = jsonDecode(source);
  if (decoded is! List) {
    throw const FormatException('Invalid Quill delta.');
  }
  final result = <Map<String, dynamic>>[];
  void append(Object insert, Map<String, dynamic>? attributes) {
    final next = attributes ?? const <String, dynamic>{};
    if (insert is String &&
        result.isNotEmpty &&
        result.last['insert'] is String) {
      final previous = result.last['attributes'] as Map? ?? const {};
      if (previous.length == next.length &&
          next.entries.every((entry) => previous[entry.key] == entry.value)) {
        result.last['insert'] = (result.last['insert'] as String) + insert;
        return;
      }
    }
    result.add({'insert': insert, if (next.isNotEmpty) 'attributes': next});
  }

  for (final raw in decoded) {
    if (raw is! Map ||
        !raw.containsKey('insert') ||
        raw.keys.any((key) => key != 'insert' && key != 'attributes')) {
      throw const FormatException('Invalid Quill insert operation.');
    }
    final previous = raw['attributes'];
    if (previous != null && previous is! Map) {
      throw const FormatException('Invalid Quill attributes.');
    }
    Map<String, dynamic>? patched(Map<String, dynamic> changes) {
      final attributes = Map<String, dynamic>.from(previous ?? const {});
      for (final entry in changes.entries) {
        if (entry.value == null) {
          attributes.remove(entry.key);
        } else {
          attributes[entry.key] = entry.value;
        }
      }
      return attributes.isEmpty ? null : attributes;
    }

    final insert = raw['insert'];
    if (insert is Map) {
      append(Map<String, dynamic>.from(insert), patched(inlineChanges));
    } else if (insert is String) {
      final lines = insert.split('\n');
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].isNotEmpty) {
          append(lines[index], patched(inlineChanges));
        }
        if (index < lines.length - 1) {
          append('\n', patched(paragraphChanges));
        }
      }
    } else {
      throw const FormatException('Invalid Quill insert content.');
    }
  }
  return jsonEncode(result);
}
