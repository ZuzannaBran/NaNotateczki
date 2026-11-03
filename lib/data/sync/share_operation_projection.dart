import 'dart:collection';
import 'dart:convert';

import 'operation_protocol.dart';
import 'operation_text_sequence.dart';

/// Deterministic v2 document projection. It never serializes viewport state.
///
/// Objects and pages are indexed by immutable IDs. Only touched nodes are
/// logically changed; no legacy notebook JSON snapshot is installed here.
class ShareOperationProjection {
  const ShareOperationProjection._(this.document, this.tombstones);

  factory ShareOperationProjection.empty() =>
      const ShareOperationProjection._(null, <String>{});

  final Map<String, dynamic>? document;
  final Set<String> tombstones;

  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  static String _pageKey(String id) => 'page:$id';
  static String _objectKey(String pageId, String objectId) =>
      'object:$pageId:$objectId';

  /// The returned value can be discarded on failure without any side effect.
  ShareOperationProjection apply(
    OperationEnvelope op, {
    bool optimistic = false,
  }) {
    op.validateForV2Projection();
    if (op.kind.target == OperationTarget.folder) {
      throw UnsupportedError('Folder operations are handled in stage 8.');
    }
    final next = document == null ? null : _copy(document!);
    final deleted = Set<String>.from(tombstones);
    final kind = op.kind;
    final documentDeleted = deleted.contains('document');

    if (kind == OperationKind.documentDelete) {
      deleted.add('document');
      return ShareOperationProjection._(null, deleted);
    }
    if (kind == OperationKind.documentCreate) {
      if (next != null || documentDeleted) {
        throw StateError('Document identity is already used.');
      }
      final created = _newNode();
      created['pages'] = <String, dynamic>{};
      _merge(created, _fields(op, create: true), op);
      return ShareOperationProjection._(created, deleted);
    }
    if (documentDeleted) {
      return ShareOperationProjection._(null, deleted);
    }
    if (next == null) {
      if (kind == OperationKind.pageDelete ||
          kind == OperationKind.objectDelete) {
        deleted.add(
          kind == OperationKind.pageDelete
              ? _pageKey(op.objectId!)
              : _objectKey(op.pageId!, op.objectId!),
        );
        return ShareOperationProjection._(null, deleted);
      }
      throw StateError('Document is not initialized.');
    }
    if (kind == OperationKind.documentSet) {
      _merge(next, _fields(op, create: false), op, force: optimistic);
      return ShareOperationProjection._(next, deleted);
    }

    final pages = next.putIfAbsent('pages', () => <String, dynamic>{})
        as Map<String, dynamic>;
    final pageId = kind.target == OperationTarget.page
        ? op.objectId!
        : op.pageId!;
    final pageKey = _pageKey(pageId);
    if (kind == OperationKind.pageDelete) {
      pages.remove(pageId);
      deleted.add(pageKey);
      return ShareOperationProjection._(next, deleted);
    }
    if (deleted.contains(pageKey)) {
      if (kind == OperationKind.pageCreate ||
          kind == OperationKind.objectCreate ||
          kind == OperationKind.strokeCreate) {
        throw StateError('Deleted page cannot be recreated.');
      }
      return ShareOperationProjection._(next, deleted);
    }
    if (kind == OperationKind.pageCreate) {
      if (pages.containsKey(pageId)) {
        throw StateError('Page identity is already used.');
      }
      final created = _newNode()..['objects'] = <String, dynamic>{};
      _merge(created, _fields(op, create: true), op);
      pages[pageId] = created;
      return ShareOperationProjection._(next, deleted);
    }
    final page = pages[pageId];
    if (page == null) {
      if (kind == OperationKind.objectDelete) {
        deleted.add(_objectKey(pageId, op.objectId!));
        return ShareOperationProjection._(next, deleted);
      }
      throw StateError('Parent page does not exist.');
    }
    if (kind == OperationKind.pageSet) {
      _merge(
        page as Map<String, dynamic>,
        _fields(op, create: false),
        op,
        force: optimistic,
      );
      return ShareOperationProjection._(next, deleted);
    }

    final objects = (page as Map<String, dynamic>)
        .putIfAbsent('objects', () => <String, dynamic>{})
        as Map<String, dynamic>;
    final objectId = op.objectId!;
    final objectKey = _objectKey(pageId, objectId);
    if (kind == OperationKind.objectDelete) {
      objects.remove(objectId);
      deleted.add(objectKey);
      return ShareOperationProjection._(next, deleted);
    }
    if (deleted.contains(objectKey)) {
      if (kind == OperationKind.objectCreate ||
          kind == OperationKind.strokeCreate) {
        throw StateError('Deleted object cannot be recreated.');
      }
      return ShareOperationProjection._(next, deleted);
    }
    if (kind == OperationKind.objectCreate ||
        kind == OperationKind.strokeCreate) {
      if (objects.containsKey(objectId)) {
        throw StateError('Object identity is already used.');
      }
      final created = _newNode()..['type'] = kind.wireName;
      _merge(created, _fields(op, create: true), op);
      objects[objectId] = created;
      return ShareOperationProjection._(next, deleted);
    }
    final object = objects[objectId];
    if (object is! Map<String, dynamic>) {
      throw StateError('Object is not initialized.');
    }
    if (kind == OperationKind.textInsert ||
        kind == OperationKind.textDelete) {
      if (object['type'] != OperationKind.objectCreate.wireName) {
        throw StateError('Text operation needs an object.');
      }
      final properties = object['properties'] as Map<String, dynamic>;
      if (!object.containsKey('textAtoms') &&
          properties['text'] != null &&
          properties['text'] != '') {
        throw StateError('Existing text requires explicit CRDT migration.');
      }
      final atoms = object['textAtoms'] is Map<String, dynamic>
          ? object['textAtoms'] as Map<String, dynamic>
          : <String, dynamic>{};
      final changed = OperationTextSequence.apply(atoms, op);
      object['textAtoms'] = changed;
      properties['text'] = OperationTextSequence.render(changed);
      return ShareOperationProjection._(next, deleted);
    }
    final fields = _fields(op, create: false);
    if (object.containsKey('textAtoms') && fields.containsKey('text')) {
      throw StateError('CRDT text cannot be replaced with object.set.');
    }
    _merge(object, fields, op, force: optimistic);
    return ShareOperationProjection._(next, deleted);
  }

  static Map<String, dynamic> _newNode() => {
    'properties': <String, dynamic>{},
    'versions': <String, dynamic>{},
  };

  static Map<String, dynamic> _fields(
    OperationEnvelope op, {
    required bool create,
  }) {
    final key = create ? 'value' : 'properties';
    return Map<String, dynamic>.from(op.payload[key] as Map);
  }

  static void _merge(
    Map<String, dynamic> node,
    Map<String, dynamic> fields,
    OperationEnvelope op, {
    bool force = false,
  }) {
    final versions = node['versions'] as Map<String, dynamic>;
    final properties = node['properties'] as Map<String, dynamic>;
    final rank = <Object>[
      op.logicalClock,
      op.actorId,
      op.actorSeq,
      op.operationId,
    ];
    for (final entry in fields.entries) {
      final previous = versions[entry.key];
      if (force ||
          previous == null ||
          _compareRanks(rank, List<Object>.from(previous as List)) > 0) {
        versions[entry.key] = rank;
        properties[entry.key] = entry.value;
      }
    }
  }

  static int _compareRanks(List<Object> left, List<Object> right) {
    for (var index = 0; index < left.length; index++) {
      final compare = index.isEven
          ? (left[index] as num).compareTo(right[index] as num)
          : (left[index] as String).compareTo(right[index] as String);
      if (compare != 0) {
        return compare;
      }
    }
    return 0;
  }
}

/// Keeps optimistic local edits above every server response until ACK.
///
/// Invalid concurrent local edits remain in the outbox as unresolved intents.
/// A server response is never allowed to silently delete an unacknowledged op.
class PendingShareProjection {
  PendingShareProjection(this.confirmed);

  ShareOperationProjection confirmed;
  final LinkedHashMap<String, OperationEnvelope> pending =
      LinkedHashMap<String, OperationEnvelope>();
  final Map<String, String> unresolved = <String, String>{};

  ShareOperationProjection get visible {
    var result = confirmed;
    unresolved.clear();
    for (final op in pending.values) {
      try {
        result = result.apply(op, optimistic: true);
      } catch (error) {
        unresolved[op.operationId] = error.toString();
      }
    }
    return result;
  }

  void enqueue(OperationEnvelope op) {
    if (pending.containsKey(op.operationId)) {
      if (jsonEncode(pending[op.operationId]!.toJson()) !=
          jsonEncode(op.toJson())) {
        throw StateError('Operation ID reused.');
      }
      return;
    }
    final proposed = LinkedHashMap<String, OperationEnvelope>.from(pending)
      ..[op.operationId] = op;
    var result = confirmed;
    for (final local in proposed.values) {
      result = result.apply(local, optimistic: true);
    }
    pending[op.operationId] = op;
  }

  void accept(OperationEnvelope remote) {
    // First commit confirmed history; echo removes only its exact local ID.
    final next = confirmed.apply(remote);
    final local = pending[remote.operationId];
    if (local != null &&
        jsonEncode(local.toJson()) != jsonEncode(remote.toJson())) {
      throw StateError('Server ACK conflicts with the local operation.');
    }
    confirmed = next;
    pending.remove(remote.operationId);
    visible;
  }
}
