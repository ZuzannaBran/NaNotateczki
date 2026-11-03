import 'operation_protocol.dart';

/// A deterministic sequence CRDT shared by account and guest editors.
///
/// Each atom has a stable UUID, immutable predecessor and insertion rank.
/// Deleted atoms remain available as anchors for delayed concurrent inserts.
class OperationTextSequence {
  static const maxAtomsPerOperation = 256;
  static const maxAtomTextLength = 1024;
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// Returns a detached atom map; errors never mutate the input projection.
  static Map<String, dynamic> apply(
    Map<String, dynamic> current,
    OperationEnvelope operation,
  ) {
    final atoms = Map<String, dynamic>.from(current);
    final payload = operation.payload;
    if (operation.kind == OperationKind.textInsert) {
      if (payload.length != 2 ||
          !payload.containsKey('afterAtomId') ||
          !payload.containsKey('atoms')) {
        throw const FormatException('Invalid text.insert payload.');
      }
      final after = payload['afterAtomId'];
      final values = payload['atoms'];
      if ((after != null && !_validId(after)) ||
          (after != null && !atoms.containsKey(after)) ||
          values is! List ||
          values.isEmpty ||
          values.length > maxAtomsPerOperation) {
        throw const FormatException('Invalid text insertion.');
      }
      final ids = <String>{};
      for (final value in values) {
        if (value is! Map ||
            value.length != 2 ||
            !value.containsKey('id') ||
            !value.containsKey('text') ||
            !_validId(value['id']) ||
            value['text'] is! String ||
            (value['text'] as String).isEmpty ||
            (value['text'] as String).runes.length > maxAtomTextLength ||
            !ids.add(value['id'] as String) ||
            atoms.containsKey(value['id'])) {
          throw const FormatException('Invalid or reused text atom.');
        }
        final text = value['text'] as String;
        if (text.runes.any((rune) => rune >= 0xD800 && rune <= 0xDFFF)) {
          throw const FormatException('Invalid Unicode text atom.');
        }
      }
      var anchor = after as String?;
      for (var index = 0; index < values.length; index++) {
        final value = values[index] as Map;
        final id = value['id'] as String;
        atoms[id] = <String, dynamic>{
          'after': anchor,
          'text': value['text'],
          'deleted': false,
          'order': <Object>[
            operation.logicalClock,
            operation.actorId,
            operation.actorSeq,
            operation.operationId,
            index,
          ],
        };
        anchor = id;
      }
    } else if (operation.kind == OperationKind.textDelete) {
      if (payload.length != 1 || !payload.containsKey('atomIds')) {
        throw const FormatException('Invalid text.delete payload.');
      }
      final ids = payload['atomIds'];
      if (ids is! List ||
          ids.isEmpty ||
          ids.length > maxAtomsPerOperation ||
          ids.toSet().length != ids.length ||
          ids.any((id) => !_validId(id) || !atoms.containsKey(id))) {
        throw const FormatException('Invalid or missing text atom.');
      }
      for (final id in ids) {
        atoms[id] = <String, dynamic>{
          ...Map<String, dynamic>.from(atoms[id] as Map),
          'deleted': true,
        };
      }
    } else {
      throw UnsupportedError('Not a text operation.');
    }
    // Validate the full graph, including deleted anchors and cycles.
    visibleIds(atoms);
    return atoms;
  }

  static bool _validId(Object? value) =>
      value is String && _uuid.hasMatch(value);

  /// Stable visible order, independent of network arrival order.
  static List<String> visibleIds(Map<String, dynamic> atoms) {
    final children = <String?, List<String>>{};
    for (final entry in atoms.entries) {
      final value = entry.value;
      if (!_validId(entry.key) || value is! Map) {
        throw const FormatException('Malformed text atom.');
      }
      final after = value['after'];
      final rank = value['order'];
      if ((after != null && !_validId(after)) ||
          (after != null && !atoms.containsKey(after)) ||
          after == entry.key ||
          rank is! List ||
          rank.length != 5 ||
          rank[0] is! int ||
          rank[1] is! String ||
          rank[2] is! int ||
          rank[3] is! String ||
          rank[4] is! int ||
          value['deleted'] is! bool ||
          value['text'] is! String) {
        throw const FormatException('Malformed text atom graph.');
      }
      children.putIfAbsent(after as String?, () => []).add(entry.key);
    }
    for (final siblings in children.values) {
      siblings.sort((a, b) {
        final left = (atoms[a] as Map)['order'] as List;
        final right = (atoms[b] as Map)['order'] as List;
        for (var i = 0; i < 5; i++) {
          final x = left[i];
          final y = right[i];
          if ((i.isEven && x is! num) ||
              (i.isOdd && x is! String) ||
              (i.isEven && y is! num) ||
              (i.isOdd && y is! String)) {
            throw const FormatException('Invalid atom rank.');
          }
          final comparison = i.isEven
              ? (x as num).compareTo(y as num)
              : (x as String).compareTo(y as String);
          if (comparison != 0) {
            return -comparison;
          }
        }
        return b.compareTo(a);
      });
    }
    final stack = <String>[...?children[null]?.reversed];
    final seen = <String>{};
    final visible = <String>[];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!seen.add(id)) {
        throw const FormatException('Cycle in text atom graph.');
      }
      if ((atoms[id] as Map)['deleted'] == false) {
        visible.add(id);
      }
      stack.addAll(children[id]?.reversed ?? const <String>[]);
    }
    if (seen.length != atoms.length) {
      throw const FormatException('Unreachable text atom graph.');
    }
    return visible;
  }

  static String render(Map<String, dynamic> atoms) =>
      visibleIds(atoms)
          .map((id) => (atoms[id] as Map)['text'] as String)
          .join();

  /// Position refers to the visible text, not tombstones or local viewport.
  static String? anchorBefore(
    Map<String, dynamic> atoms,
    int visibleAtomIndex,
  ) {
    final ids = visibleIds(atoms);
    if (visibleAtomIndex < 0 || visibleAtomIndex > ids.length) {
      throw RangeError.range(visibleAtomIndex, 0, ids.length);
    }
    return visibleAtomIndex == 0 ? null : ids[visibleAtomIndex - 1];
  }
}
