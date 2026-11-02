import 'package:collection/collection.dart';

const _equality = DeepCollectionEquality();

/// Combines independent changes or reports a collision with null.
Map<String, dynamic>? mergeNotebookChanges(
  Map<String, dynamic> base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote,
) {
  if (base['uid'] != local['uid'] || base['uid'] != remote['uid']) {
    return null;
  }
  try {
    return _mergeMap(base, local, remote);
  } on _MergeConflict {
    return null;
  }
}

class _MergeConflict implements Exception {}

bool _same(Object? first, Object? second) => _equality.equals(first, second);

Map<String, dynamic> _mergeMap(
  Map<String, dynamic> base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote,
) {
  final result = <String, dynamic>{};
  for (final key in {...base.keys, ...remote.keys, ...local.keys}) {
    final before = base[key];
    final changed = local[key];
    final current = remote[key];
    if (key == 'updatedAt' &&
        before is String &&
        changed is String &&
        current is String) {
      final a = DateTime.parse(changed).toUtc();
      final b = DateTime.parse(current).toUtc();
      result[key] = (a.isAfter(b) ? a : b).toIso8601String();
    } else if (_same(changed, before)) {
      result[key] = current;
    } else if (_same(current, before) || _same(changed, current)) {
      result[key] = changed;
    } else if (before is Map<String, dynamic> &&
        changed is Map<String, dynamic> &&
        current is Map<String, dynamic>) {
      result[key] = _mergeMap(before, changed, current);
    } else if (_isIdList(key) &&
        before is List &&
        changed is List &&
        current is List) {
      result[key] = _mergeIdList(before, changed, current);
    } else {
      throw _MergeConflict();
    }
  }
  return result;
}

bool _isIdList(String key) =>
    key == 'pages' ||
    key == 'inkStrokes' ||
    key == 'textBlocks' ||
    key == 'imageBlocks';

Map<String, Map<String, dynamic>> _byId(List<dynamic> items) {
  final result = <String, Map<String, dynamic>>{};
  for (final item in items) {
    if (item is! Map<String, dynamic>) {
      throw _MergeConflict();
    }
    final id = item['id'];
    if (id is! String || id.isEmpty || result.containsKey(id)) {
      throw _MergeConflict();
    }
    result[id] = item;
  }
  return result;
}

List<Map<String, dynamic>> _mergeIdList(
  List<dynamic> base,
  List<dynamic> local,
  List<dynamic> remote,
) {
  final old = _byId(base);
  final changed = _byId(local);
  final current = _byId(remote);
  final merged = <String, Map<String, dynamic>>{};
  for (final id in {...current.keys, ...changed.keys, ...old.keys}) {
    final before = old[id];
    final after = changed[id];
    final actual = current[id];
    Map<String, dynamic>? next;
    if (_same(after, before)) {
      next = actual;
    } else if (_same(actual, before) || _same(after, actual)) {
      next = after;
    } else if (before != null && after != null && actual != null) {
      next = _mergeMap(before, after, actual);
    } else {
      throw _MergeConflict();
    }
    if (next != null) {
      merged[id] = next;
    }
  }
  return merged.values.toList();
}
