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

  /// Copy only the modified branch; untouched page/object maps are shared.
  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(value);

  static String _pageKey(String id) => 'page:$id';
  static String _objectKey(String pageId, String objectId) =>
      'object:$pageId:$objectId';

  /// The returned value can be discarded on failure without any side effect.
  ShareOperationProjection apply(
    OperationEnvelope op, {
    bool optimistic = false,
    Set<String> verifiedAssets = const <String>{},
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

    final pages = Map<String, dynamic>.from(
      next['pages'] as Map? ?? const <String, dynamic>{},
    );
    next['pages'] = pages;
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
      final mutablePage = Map<String, dynamic>.from(page as Map);
      pages[pageId] = mutablePage;
      _merge(mutablePage, _fields(op, create: false), op, force: optimistic);
      return ShareOperationProjection._(next, deleted);
    }

    final mutablePage = Map<String, dynamic>.from(page as Map);
    pages[pageId] = mutablePage;
    final objects = Map<String, dynamic>.from(
      mutablePage['objects'] as Map? ?? const <String, dynamic>{},
    );
    mutablePage['objects'] = objects;
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
    if (kind == OperationKind.objectMove) {
      final destinationId = op.payload['toPageId'] as String;
      final sortIndex = op.payload['sortIndex'] as int;
      final destination = pages[destinationId];
      if (destination is! Map ||
          deleted.contains(_pageKey(destinationId)) ||
          destinationId == pageId) {
        throw StateError('Destination page is not available.');
      }
      final moved = objects[objectId];
      if (moved is! Map<String, dynamic>) {
        throw StateError('Source object is not available.');
      }
      final nextDestination = Map<String, dynamic>.from(destination);
      final destinationObjects = Map<String, dynamic>.from(
        nextDestination['objects'] as Map? ?? const <String, dynamic>{},
      );
      if (destinationObjects.containsKey(objectId) ||
          deleted.contains(_objectKey(destinationId, objectId))) {
        throw StateError('Destination identity is occupied.');
      }
      final nextObject = Map<String, dynamic>.from(moved);
      _merge(nextObject, {'sortIndex': sortIndex}, op, force: optimistic);
      objects.remove(objectId);
      destinationObjects[objectId] = nextObject;
      nextDestination['objects'] = destinationObjects;
      pages[destinationId] = nextDestination;
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
    final mutableObject = Map<String, dynamic>.from(object);
    objects[objectId] = mutableObject;
    if (kind == OperationKind.assetAttach ||
        kind == OperationKind.assetDetach) {
      final assetId = op.payload['assetId'] as String;
      final digest = op.payload['sha256'];
      if (kind == OperationKind.assetAttach &&
          optimistic &&
          !verifiedAssets.contains(digest)) {
        throw StateError('Asset upload must be verified before local attach.');
      }
      final versions = Map<String, dynamic>.from(
        mutableObject['assetVersions'] as Map? ?? const <String, dynamic>{},
      );
      final assets = Map<String, dynamic>.from(
        mutableObject['assets'] as Map? ?? const <String, dynamic>{},
      );
      final rank = <Object>[
        op.logicalClock,
        op.actorId,
        op.actorSeq,
        op.operationId,
      ];
      final previous = versions[assetId];
      if (previous == null ||
          _compareRanks(rank, List<Object>.from(previous as List)) > 0) {
        final old = assets[assetId];
        final replacing =
            kind == OperationKind.assetAttach &&
            old is Map &&
            (old['sha256'] != digest ||
                old['sizeBytes'] != op.payload['sizeBytes'] ||
                old['mediaType'] != op.payload['mediaType']);
        if ((kind == OperationKind.assetDetach || replacing) &&
            _referencesAsset(mutableObject, assetId)) {
          throw StateError('Cannot detach or replace an embedded asset.');
        }
        if (kind == OperationKind.assetAttach) {
          assets[assetId] = {
            'sha256': digest,
            'sizeBytes': op.payload['sizeBytes'],
            'mediaType': op.payload['mediaType'],
          };
        } else {
          assets.remove(assetId);
        }
        versions[assetId] = rank;
      }
      mutableObject['assetVersions'] = versions;
      mutableObject['assets'] = assets;
      return ShareOperationProjection._(next, deleted);
    }
    if (kind == OperationKind.textInsert ||
        kind == OperationKind.textDelete ||
        kind == OperationKind.textFormat) {
      final properties = Map<String, dynamic>.from(
        mutableObject['properties'] as Map,
      );
      if (mutableObject['type'] != OperationKind.objectCreate.wireName ||
          properties['objectType'] != 'text') {
        throw StateError('Text operation needs a typed text object.');
      }
      if (!mutableObject.containsKey('textAtoms') &&
          properties['text'] != null &&
          properties['text'] != '') {
        throw StateError('Existing text requires explicit CRDT migration.');
      }
      final atoms = mutableObject['textAtoms'] is Map<String, dynamic>
          ? mutableObject['textAtoms'] as Map<String, dynamic>
          : <String, dynamic>{};
      if (kind == OperationKind.textInsert) {
        final attached = mutableObject['assets'] as Map? ?? const {};
        for (final raw in op.payload['atoms'] as List) {
          final atom = raw as Map;
          if (atom.containsKey('embed')) {
            final embed = atom['embed'] as Map;
            final id = OperationEnvelope.embedAssetId(embed);
            final asset = attached[id];
            final mime = asset is Map ? asset['mediaType'] : null;
            final validMime = embed.containsKey('pdf')
                ? mime == 'application/pdf'
                : mime == 'image/png' ||
                      mime == 'image/jpeg' ||
                      mime == 'image/webp';
            if (!validMime) {
              throw StateError(
                'Quill embed requires a matching attached asset.',
              );
            }
          }
        }
      }
      final changed = OperationTextSequence.apply(atoms, op);
      mutableObject['textAtoms'] = changed;
      mutableObject['properties'] = properties;
      properties['text'] = OperationTextSequence.render(changed);
      properties['delta'] = OperationTextSequence.renderDelta(changed);
      return ShareOperationProjection._(next, deleted);
    }
    final fields = _fields(op, create: false);
    if (mutableObject.containsKey('textAtoms') &&
        (fields.containsKey('text') || fields.containsKey('delta'))) {
      throw StateError('CRDT text cannot be replaced with object.set.');
    }
    _merge(mutableObject, fields, op, force: optimistic);
    return ShareOperationProjection._(next, deleted);
  }

  static bool _referencesAsset(Map<String, dynamic> object, String assetId) {
    final atoms = object['textAtoms'];
    if (atoms == null) {
      return false;
    }
    if (atoms is! Map<String, dynamic>) {
      throw const FormatException('Invalid text atom collection.');
    }
    for (final id in OperationTextSequence.visibleIds(atoms)) {
      final atom = atoms[id] as Map;
      if (atom.containsKey('embed') &&
          OperationEnvelope.embedAssetId(atom['embed']) == assetId) {
        return true;
      }
    }
    return false;
  }

  /// Stable canvas z-order regardless of JSON or SQLite map key ordering.
  List<String> orderedObjectIds(String pageId) {
    final pages = document?['pages'];
    if (pages is! Map) {
      return const <String>[];
    }
    final page = pages[pageId];
    if (page == null) {
      return const <String>[];
    }
    if (page is! Map || page['objects'] is! Map) {
      throw const FormatException('Invalid page object collection.');
    }
    final objects = page['objects'] as Map;
    int rank(String id) {
      final node = objects[id];
      if (node is! Map || node['properties'] is! Map) {
        throw const FormatException('Invalid projected object.');
      }
      final order = (node['properties'] as Map)['sortIndex'] ?? 0;
      if (order is! int || order < 0 || order >= 1000000) {
        throw const FormatException('Invalid object z-order.');
      }
      return order;
    }

    final ids = objects.keys.cast<String>().toList();
    ids.sort((a, b) {
      final comparison = rank(a).compareTo(rank(b));
      return comparison != 0 ? comparison : a.compareTo(b);
    });
    return ids;
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
    final versions = Map<String, dynamic>.from(node['versions'] as Map);
    final properties = Map<String, dynamic>.from(node['properties'] as Map);
    node['versions'] = versions;
    node['properties'] = properties;
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
  PendingShareProjection(this.confirmed, {Set<String>? verifiedAssetDigests})
    : verifiedAssets = verifiedAssetDigests ?? <String>{};

  ShareOperationProjection confirmed;

  /// Only digests with confirmed upload and local checksum may be added.
  final Set<String> verifiedAssets;

  void markAssetVerified(String digest) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid verified asset digest.');
    }
    verifiedAssets.add(digest);
  }

  final LinkedHashMap<String, OperationEnvelope> pending =
      LinkedHashMap<String, OperationEnvelope>();
  final Map<String, String> unresolved = <String, String>{};

  ShareOperationProjection get visible {
    var result = confirmed;
    unresolved.clear();
    for (final op in pending.values) {
      final targetDeleted =
          result.tombstones.contains('document') ||
          (op.pageId != null &&
              result.tombstones.contains('page:${op.pageId}')) ||
          (op.objectId != null &&
              op.pageId != null &&
              result.tombstones.contains('object:${op.pageId}:${op.objectId}'));
      if (targetDeleted && !op.kind.wireName.endsWith('.delete')) {
        unresolved[op.operationId] =
            'The target was deleted remotely; keep this pending edit.';
        continue;
      }
      try {
        result = result.apply(
          op,
          optimistic: true,
          verifiedAssets: verifiedAssets,
        );
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
      result = result.apply(
        local,
        optimistic: true,
        verifiedAssets: verifiedAssets,
      );
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
