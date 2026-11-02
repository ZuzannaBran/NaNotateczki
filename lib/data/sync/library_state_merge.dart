import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Reconciles separately changed folder metadata using the last acknowledged
/// account snapshot as a three-way base. Absence relative to that base is
/// an explicit deletion, not an invitation to resurrect older backup data.
Map<String, dynamic> mergeAccountLibraryState({
  required Object? base,
  required Object? local,
  required Object? remote,
}) {
  Map<String, dynamic> object(Object? value) =>
      value is Map<String, dynamic> ? value : <String, dynamic>{};
  final b = object(base);
  final l = object(local);
  final r = object(remote);
  final mergedFolders = _mergeNamedValues(
    _folderMap(b['folders']),
    _folderMap(l['folders']),
    _folderMap(r['folders']),
    baseKnown: base != null,
  );
  final mergedCovers = _mergeNamedValues(
    object(b['covers']),
    object(l['covers']),
    object(r['covers']),
    baseKnown: base != null,
  );
  final taskGroups = _mergeTaskGroups(
    object(b['plannerTasks']),
    object(l['plannerTasks']),
    object(r['plannerTasks']),
    baseKnown: base != null,
  );
  final recent = _recentColors(
    r['recentCoverColors'] ?? l['recentCoverColors'],
  );
  return {
    'folders': mergedFolders.keys.toList()..sort(),
    'covers': mergedCovers,
    'plannerTasks': taskGroups,
    'recentCoverColors': recent,
  };
}

Map<String, dynamic> _folderMap(Object? raw) => {
  if (raw is List)
    for (final name in raw.whereType<String>()) name: true,
};

List<int> _recentColors(Object? raw) {
  if (raw is! List) {
    return <int>[];
  }
  return raw.whereType<int>().toSet().take(12).toList();
}

bool _equal(Object? a, Object? b) => jsonEncode(_canonical(a)) ==
    jsonEncode(_canonical(b));

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.whereType<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) {
    return value.map(_canonical).toList();
  }
  return value;
}

Map<String, dynamic> _mergeNamedValues(
  Map<String, dynamic> base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote, {
  required bool baseKnown,
}) {
  final result = <String, dynamic>{};
  final names = {...base.keys, ...local.keys, ...remote.keys}.toList()..sort();
  for (final key in names) {
    final inBase = base.containsKey(key);
    final inLocal = local.containsKey(key);
    final inRemote = remote.containsKey(key);
    if (!baseKnown && inRemote) {
      result[key] = remote[key];
      continue;
    }
    if (!baseKnown && inLocal) {
      result[key] = local[key];
      continue;
    }
    final localChanged = inLocal != inBase ||
        (inLocal && !_equal(local[key], base[key]));
    final remoteChanged = inRemote != inBase ||
        (inRemote && !_equal(remote[key], base[key]));
    if (localChanged && !remoteChanged && inLocal) {
      result[key] = local[key];
    } else if (remoteChanged && !localChanged && inRemote) {
      result[key] = remote[key];
    } else if (localChanged && remoteChanged) {
      // Deletion takes precedence over concurrent edits to the same key.
      if (inLocal && inRemote) {
        result[key] = remote[key];
      }
    } else if (inRemote) {
      result[key] = remote[key];
    }
  }
  return result;
}

Map<String, dynamic> _taskIndex(Object? value) {
  if (value is! List) {
    return <String, dynamic>{};
  }
  return {
    for (final raw in value)
      if (raw is Map<String, dynamic> &&
          raw['id'] is String &&
          (raw['id'] as String).isNotEmpty)
        raw['id'] as String: raw,
  };
}

Map<String, dynamic> _mergeTaskGroups(
  Map<String, dynamic> base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote, {
  required bool baseKnown,
}) {
  final merged = <String, dynamic>{};
  final groups = {...base.keys, ...local.keys, ...remote.keys}.toList()..sort();
  for (final uid in groups) {
    // A removed planner's tasks must not be restored by an offline device.
    if (baseKnown && base.containsKey(uid) &&
        !remote.containsKey(uid) && !local.containsKey(uid)) {
      continue;
    }
    final entries = _mergeNamedValues(
      _taskIndex(base[uid]),
      _taskIndex(local[uid]),
      _taskIndex(remote[uid]),
      baseKnown: baseKnown,
    );
    // Preserve an unsent task edit that raced with a server-side deletion
    // as a distinct recoverable task, without resurrecting its original ID.
    if (baseKnown) {
      final old = _taskIndex(base[uid]);
      final changed = _taskIndex(local[uid]);
      final server = _taskIndex(remote[uid]);
      for (final id in old.keys) {
        if (!server.containsKey(id) &&
            changed.containsKey(id) &&
            !_equal(changed[id], old[id])) {
          final original = changed[id] as Map<String, dynamic>;
          final signature = sha256
              .convert(utf8.encode(jsonEncode(_canonical(original))))
              .toString()
              .substring(0, 12);
          final copyId = '$id-conflict-$signature';
          entries[copyId] = {
            ...original,
            'id': copyId,
            'title': '${original['title']} (1)',
          };
        }
      }
    }
    if (entries.isNotEmpty ||
        (remote.containsKey(uid) && remote[uid] is List)) {
      merged[uid] = entries.values.toList();
    }
  }
  return merged;
}
