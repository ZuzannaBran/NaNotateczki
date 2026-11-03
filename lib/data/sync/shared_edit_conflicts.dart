/// Detects edits not present in the server's accepted, merged document.
///
/// Independent changes to other objects are not conflicts.
bool hasRejectedSharedEdits(
  Map<String, dynamic> base,
  Map<String, dynamic> submitted,
  Map<String, dynamic> accepted,
) {
  final oldPages = _byId(base['pages']);
  final newPages = _byId(submitted['pages']);
  final serverPages = _byId(accepted['pages']);
  for (final id in {...oldPages.keys, ...newPages.keys}) {
    final before = oldPages[id];
    final after = newPages[id];
    if (_sameValue(before, after)) {
      continue;
    }
    final actual = serverPages[id];
    if (before == null || after == null) {
      if (!_sameValue(after, actual)) {
        return true;
      }
      continue;
    }
    if (actual == null) {
      return true;
    }
    for (final key in {...before.keys, ...after.keys}) {
      if (key == 'id') {
        continue;
      }
      if (const {'inkStrokes', 'textBlocks', 'imageBlocks'}.contains(key)) {
        final oldItems = _byId(before[key]);
        final newItems = _byId(after[key]);
        final acceptedItems = _byId(actual[key]);
        for (final itemId in {...oldItems.keys, ...newItems.keys}) {
          if (!_sameValue(oldItems[itemId], newItems[itemId]) &&
              !_sameValue(newItems[itemId], acceptedItems[itemId])) {
            return true;
          }
        }
      } else if (!_sameValue(before[key], after[key]) &&
          !_sameValue(after[key], actual[key])) {
        return true;
      }
    }
  }
  return false;
}

/// A delayed network snapshot must never replace a newer confirmation or
/// editor content that has changed before its local save notification.
bool canInstallSharedGuestRevision({
  required int incomingRevision,
  required int confirmedRevision,
  required Map<String, dynamic> expectedLocal,
  required Map<String, dynamic> visibleLocal,
}) =>
    incomingRevision >= confirmedRevision &&
    _sameValue(expectedLocal['pages'], visibleLocal['pages']);

Map<String, Map<String, dynamic>> _byId(Object? items) {
  final indexed = <String, Map<String, dynamic>>{};
  if (items is! List) {
    return indexed;
  }
  for (final item in items) {
    if (item is Map<String, dynamic> && item['id'] is String) {
      indexed[item['id'] as String] = item;
    }
  }
  return indexed;
}

bool _sameValue(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final key in left.keys) {
      if (!right.containsKey(key) || !_sameValue(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i++) {
      if (!_sameValue(left[i], right[i])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
