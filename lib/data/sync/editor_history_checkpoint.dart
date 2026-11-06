import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// A resource limit is distinct from corrupt or incorrectly scoped history.
class EditorHistoryBudgetExceeded extends FormatException {
  const EditorHistoryBudgetExceeded(super.message);
}

String _canonical(Object? value) {
  Object? normalize(Object? value, [int depth = 0]) {
    if (depth > 64) {
      throw const FormatException('History state is too deeply nested.');
    }
    if (value is Map) {
      if (value.keys.any((key) => key is! String)) {
        throw const FormatException('History object keys must be strings.');
      }
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: normalize(value[key], depth + 1)};
    }
    if (value is List) {
      return value.map((item) => normalize(item, depth + 1)).toList();
    }
    if (value == null ||
        value is String ||
        value is bool ||
        (value is num && value.isFinite)) {
      return value;
    }
    throw const FormatException('History contains a non-JSON value.');
  }

  return jsonEncode(normalize(value));
}

String _digest(String value) =>
    crypto.sha256.convert(utf8.encode(value)).toString();

void _identity(String value) {
  if (value.isEmpty ||
      value.length > 256 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException('Invalid history identity.');
  }
}

/// Immutable state references for one already committed, local gesture.
class StoredEditorGesture {
  StoredEditorGesture({
    required Map<String, dynamic> before,
    required Map<String, dynamic> after,
    required this.operationId,
  }) : beforeJson = _canonical(before),
       afterJson = _canonical(after) {
    _identity(operationId);
  }

  final String beforeJson;
  final String afterJson;
  final String operationId;
  Map<String, dynamic> get before =>
      Map<String, dynamic>.from(jsonDecode(beforeJson) as Map);
  Map<String, dynamic> get after =>
      Map<String, dynamic>.from(jsonDecode(afterJson) as Map);
}

/// Local history metadata, never an authoritative notebook or a sync payload.
/// Shared states are content-addressed to avoid duplicating adjacent boundaries.
class EditorHistoryCheckpoint {
  EditorHistoryCheckpoint({
    required this.documentId,
    required this.ownerId,
    required this.headOperationId,
    required List<StoredEditorGesture> undo,
    required List<StoredEditorGesture> redo,
  }) : undo = List.unmodifiable(undo),
       redo = List.unmodifiable(redo) {
    for (final id in [documentId, ownerId, headOperationId]) {
      _identity(id);
    }
    if (undo.length + redo.length > maximumGestures) {
      throw const FormatException('History exceeds its gesture budget.');
    }
    final ids = <String>{};
    for (final gesture in [...undo, ...redo]) {
      if (!ids.add(gesture.operationId) ||
          gesture.before['uid'] != documentId ||
          gesture.after['uid'] != documentId) {
        throw const FormatException(
          'History gesture scope or identity mismatch.',
        );
      }
    }
  }

  static const maximumGestures = 50;
  static const maximumBytes = 4 * 1024 * 1024;
  final String documentId;

  /// The document-scoped, persistent local actor ID.
  final String ownerId;
  final String headOperationId;
  final List<StoredEditorGesture> undo;
  final List<StoredEditorGesture> redo;

  /// Keeps the nearest Undo/Redo boundaries without changing this checkpoint.
  /// Oldest Undo is discarded first, then the farthest Redo. An empty history
  /// still retains its document, actor and committed operation identity.
  EditorHistoryCheckpoint fitToByteBudget({int byteLimit = maximumBytes}) {
    try {
      encode(byteLimit: byteLimit);
      return this;
    } on EditorHistoryBudgetExceeded {
      // Removing boundaries can only reduce JSON and its referenced states.
      // Binary search avoids encoding a large history once per removed entry.
      EditorHistoryCheckpoint afterDropping(int count) =>
          EditorHistoryCheckpoint(
            documentId: documentId,
            ownerId: ownerId,
            headOperationId: headOperationId,
            undo: undo.sublist(count < undo.length ? count : undo.length),
            redo: redo.sublist(count > undo.length ? count - undo.length : 0),
          );
      final total = undo.length + redo.length;
      var best = afterDropping(total);
      best.encode(byteLimit: byteLimit);
      var low = 1;
      var high = total;
      while (low <= high) {
        final middle = (low + high) ~/ 2;
        final candidate = afterDropping(middle);
        try {
          candidate.encode(byteLimit: byteLimit);
          best = candidate;
          high = middle - 1;
        } on EditorHistoryBudgetExceeded {
          low = middle + 1;
        }
      }
      return best;
    }
  }

  String encode({int byteLimit = maximumBytes}) {
    if (byteLimit < 1 || byteLimit > maximumBytes) {
      throw ArgumentError('Invalid history size limit.');
    }
    final states = <String, Object?>{};
    String state(String json) {
      final digest = _digest(json);
      states.putIfAbsent(digest, () => jsonDecode(json));
      return digest;
    }

    List<Map<String, dynamic>> entries(List<StoredEditorGesture> gestures) => [
      for (final gesture in gestures)
        {
          'before': state(gesture.beforeJson),
          'after': state(gesture.afterJson),
          'operationId': gesture.operationId,
        },
    ];
    final before = entries(undo);
    final after = entries(redo);
    final json = _canonical({
      'version': 1,
      'documentId': documentId,
      'ownerId': ownerId,
      'headOperationId': headOperationId,
      'states': states,
      'undo': before,
      'redo': after,
    });
    if (utf8.encode(json).length > byteLimit) {
      throw const EditorHistoryBudgetExceeded(
        'History exceeds its byte budget.',
      );
    }
    return json;
  }

  static EditorHistoryCheckpoint decode(String json) {
    if (json.length > maximumBytes || utf8.encode(json).length > maximumBytes) {
      throw const EditorHistoryBudgetExceeded(
        'History exceeds its byte budget.',
      );
    }
    final root = jsonDecode(json);
    const keys = {
      'version',
      'documentId',
      'ownerId',
      'headOperationId',
      'states',
      'undo',
      'redo',
    };
    if (root is! Map ||
        root.length != keys.length ||
        !root.keys.toSet().containsAll(keys) ||
        root['version'] is! int ||
        root['version'] != 1 ||
        root['documentId'] is! String ||
        root['ownerId'] is! String ||
        root['headOperationId'] is! String ||
        root['states'] is! Map ||
        root['undo'] is! List ||
        root['redo'] is! List) {
      throw const FormatException(
        'Unsupported or malformed history checkpoint.',
      );
    }
    final states = root['states'] as Map;
    if (states.length > maximumGestures * 2 ||
        (root['undo'] as List).length + (root['redo'] as List).length >
            maximumGestures) {
      throw const FormatException('History exceeds its gesture budget.');
    }
    final referenced = <String>{};
    Map<String, dynamic> state(Object? key) {
      final value = states[key];
      if (key is! String ||
          value is! Map ||
          _digest(_canonical(value)) != key) {
        throw const FormatException('History state checksum mismatch.');
      }
      referenced.add(key);
      return Map<String, dynamic>.from(value);
    }

    List<StoredEditorGesture> entries(List raw) => raw.map((entry) {
      if (entry is! Map ||
          entry.length != 3 ||
          entry['operationId'] is! String) {
        throw const FormatException('Malformed history gesture.');
      }
      return StoredEditorGesture(
        before: state(entry['before']),
        after: state(entry['after']),
        operationId: entry['operationId'] as String,
      );
    }).toList();
    final checkpoint = EditorHistoryCheckpoint(
      documentId: root['documentId'] as String,
      ownerId: root['ownerId'] as String,
      headOperationId: root['headOperationId'] as String,
      undo: entries(root['undo'] as List),
      redo: entries(root['redo'] as List),
    );
    if (referenced.length != states.length) {
      throw const FormatException('History has unreferenced state.');
    }
    return checkpoint;
  }
}
