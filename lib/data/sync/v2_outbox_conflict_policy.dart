import 'operation_protocol.dart';

/// Conservative, side-effect-free conflict gate for the v2 SQLite reducer.
///
/// A permitted remote operation must commute with every pending local
/// operation. Neither the original outbox nor actor sequencing is rewritten.
/// Conflicting operations still wait for acknowledgement and full rebase.
class V2OutboxConflictPolicy {
  const V2OutboxConflictPolicy._();

  static bool canApply(
    OperationEnvelope remote,
    List<OperationEnvelope> pendingLocal,
  ) {
    if (pendingLocal.isEmpty) {
      return true;
    }
    return pendingLocal.every((local) {
      if (local.documentId != remote.documentId) {
        return false;
      }
      if (remote.kind == OperationKind.documentSet ||
          remote.kind == OperationKind.pageSet) {
        return _independentMetadata(remote, local);
      }
      if (remote.kind.target != OperationTarget.object ||
          local.kind.target != OperationTarget.object) {
        return false;
      }
      if (remote.objectId == local.objectId) {
        return _independentProperties(remote, local) ||
            _independentText(remote, local);
      }
      final remoteAssets = _assetIds(remote);
      final localAssets = _assetIds(local);
      return remoteAssets != null &&
          localAssets != null &&
          remoteAssets.intersection(localAssets).isEmpty;
    });
  }

  static bool _independentMetadata(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    if (local.kind.target == OperationTarget.object) {
      return true;
    }
    final remoteDocument = remote.kind == OperationKind.documentSet;
    final remotePage = remote.kind == OperationKind.pageSet;
    final localDocument = local.kind == OperationKind.documentSet;
    final localPage = local.kind == OperationKind.pageSet;
    if ((remoteDocument && localPage) || (remotePage && localDocument)) {
      return true;
    }
    if ((remoteDocument && localDocument) || (remotePage && localPage)) {
      if (remotePage && remote.objectId != local.objectId) {
        return true;
      }
      return _disjointPropertyNames(remote, local);
    }
    return false;
  }

  static bool _independentProperties(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    const kinds = {
      OperationKind.objectSet,
      OperationKind.objectTransform,
      OperationKind.objectReorder,
    };
    return kinds.contains(remote.kind) &&
        kinds.contains(local.kind) &&
        remote.pageId == local.pageId &&
        _disjointPropertyNames(remote, local);
  }

  static bool _disjointPropertyNames(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    final first = remote.payload['properties'];
    final second = local.payload['properties'];
    if (first is! Map ||
        second is! Map ||
        first.isEmpty ||
        second.isEmpty ||
        first.containsKey('assetId') ||
        second.containsKey('assetId')) {
      return false;
    }
    return first.keys.toSet().intersection(second.keys.toSet()).isEmpty;
  }

  static bool _independentText(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    if (remote.pageId != local.pageId) {
      return false;
    }
    const kinds = {
      OperationKind.textInsert,
      OperationKind.textDelete,
      OperationKind.textFormat,
    };
    if (!kinds.contains(remote.kind) || !kinds.contains(local.kind)) {
      return false;
    }
    final remoteIds = _atomIds(remote);
    final localIds = _atomIds(local);
    if (remoteIds == null || localIds == null) {
      return false;
    }
    final common = remoteIds.intersection(localIds);
    if (remote.kind == OperationKind.textFormat &&
        local.kind == OperationKind.textFormat) {
      if (common.isEmpty) {
        return true;
      }
      final first = remote.payload['attributes'];
      final second = local.payload['attributes'];
      return first is Map &&
          second is Map &&
          first.keys.toSet().intersection(second.keys.toSet()).isEmpty;
    }
    if (common.isNotEmpty) {
      return false;
    }
    // A remote insert must not depend on an unacknowledged local atom.
    if (remote.kind == OperationKind.textInsert &&
        local.kind == OperationKind.textInsert &&
        (localIds.contains(remote.payload['afterAtomId']) ||
            remoteIds.contains(local.payload['afterAtomId']))) {
      return false;
    }
    // An insertion anchored to an atom concurrently deleted by another
    // client needs explicit causal rebase, even if both sets are disjoint.
    if (remote.kind == OperationKind.textInsert &&
        local.kind == OperationKind.textDelete &&
        localIds.contains(remote.payload['afterAtomId'])) {
      return false;
    }
    if (local.kind == OperationKind.textInsert &&
        remote.kind == OperationKind.textDelete &&
        remoteIds.contains(local.payload['afterAtomId'])) {
      return false;
    }
    // Concurrent unique inserts, disjoint deletes and independent
    // formatting use the same atom-ID CRDT in Dart and PostgreSQL.
    return true;
  }

  static Set<String>? _atomIds(OperationEnvelope operation) {
    if (operation.kind == OperationKind.textInsert) {
      final atoms = operation.payload['atoms'];
      if (atoms is! List) {
        return null;
      }
      final ids = <String>{};
      for (final atom in atoms) {
        if (atom is! Map || atom['id'] is! String) {
          return null;
        }
        ids.add(atom['id'] as String);
      }
      return ids;
    }
    final raw = operation.payload['atomIds'];
    if (raw is! List || raw.any((id) => id is! String)) {
      return null;
    }
    return raw.cast<String>().toSet();
  }

  static Set<String>? _assetIds(OperationEnvelope operation) {
    final ids = <String>{};
    if (operation.kind == OperationKind.assetAttach ||
        operation.kind == OperationKind.assetDetach) {
      final id = operation.payload['assetId'];
      if (id is! String) {
        return null;
      }
      ids.add(id);
    }
    if (operation.kind == OperationKind.objectSet) {
      final properties = operation.payload['properties'];
      if (properties is Map && properties.containsKey('assetId')) {
        final id = properties['assetId'];
        if (id is! String) {
          return null;
        }
        ids.add(id);
      }
    }
    if (operation.kind == OperationKind.textInsert) {
      final atoms = operation.payload['atoms'];
      if (atoms is! List) {
        return null;
      }
      for (final atom in atoms) {
        if (atom is! Map) {
          return null;
        }
        if (!atom.containsKey('embed')) {
          continue;
        }
        try {
          ids.add(OperationEnvelope.embedAssetId(atom['embed']));
        } on FormatException {
          return null;
        }
      }
    }
    return ids;
  }
}
