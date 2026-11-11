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
      if (remote.kind == OperationKind.pageCreate) {
        return _independentPageCreate(remote, local);
      }
      if (local.kind == OperationKind.pageCreate) {
        return _independentPageCreate(local, remote);
      }
      if (remote.kind == OperationKind.pageDelete) {
        return _independentPageDelete(remote, local);
      }
      if (local.kind == OperationKind.pageDelete) {
        return _independentPageDelete(local, remote);
      }
      if (remote.kind == OperationKind.documentSet ||
          remote.kind == OperationKind.pageSet) {
        return _independentMetadata(remote, local);
      }
      if (local.kind == OperationKind.documentSet ||
          local.kind == OperationKind.pageSet) {
        // The same metadata/object pair must commute in both directions.
        return _independentMetadata(local, remote);
      }
      if (remote.kind.target != OperationTarget.object ||
          local.kind.target != OperationTarget.object) {
        return false;
      }
      final remoteAssets = _assetIds(remote);
      final localAssets = _assetIds(local);
      if (remoteAssets == null || localAssets == null) {
        return false;
      }
      if (remoteAssets.intersection(localAssets).isNotEmpty) {
        return _identicalAssetReceiptForIndependentOwners(remote, local);
      }
      if (remote.objectId == local.objectId) {
        return _independentSamePageMove(remote, local) ||
            _independentProperties(remote, local) ||
            _independentText(remote, local) ||
            _independentTextAndGeometry(remote, local);
      }
      return true;
    });
  }

  /// Reusing a verified immutable asset across two owners is safe.
  ///
  /// A create, embed or replacement carries no complete receipt and still
  /// blocks on a matching ID. Different bytes can never share one asset ID.
  static bool _identicalAssetReceiptForIndependentOwners(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    if (remote.kind != OperationKind.assetAttach ||
        local.kind != OperationKind.assetAttach ||
        remote.objectId == local.objectId) {
      return false;
    }
    const fields = {'assetId', 'sha256', 'sizeBytes', 'mediaType'};
    return remote.payload.keys.toSet().containsAll(fields) &&
        local.payload.keys.toSet().containsAll(fields) &&
        remote.payload.length == fields.length &&
        local.payload.length == fields.length &&
        fields.every((field) => remote.payload[field] == local.payload[field]);
  }

  /// A new page appends a fresh identity without touching existing pages.
  ///
  /// Deleting a distinct object on an existing page also commutes. Page
  /// deletion, container moves and concurrent page creations remain blocked.
  static bool _independentPageCreate(
    OperationEnvelope created,
    OperationEnvelope other,
  ) {
    if (created.objectId == null) {
      return false;
    }
    if (other.kind == OperationKind.documentSet) {
      return true;
    }
    if (other.kind == OperationKind.objectMove) {
      return _moveAvoidsPage(other, created.objectId!);
    }
    if (other.kind == OperationKind.pageSet) {
      return other.objectId != created.objectId;
    }
    const independentObjects = {
      OperationKind.strokeCreate,
      OperationKind.objectCreate,
      OperationKind.objectSet,
      OperationKind.objectTransform,
      OperationKind.objectReorder,
      OperationKind.objectDelete,
      OperationKind.textInsert,
      OperationKind.textDelete,
      OperationKind.textFormat,
      OperationKind.assetAttach,
      OperationKind.assetDetach,
    };
    return other.pageId != null &&
        other.pageId != created.objectId &&
        independentObjects.contains(other.kind);
  }

  /// Removing one page leaves unrelated page IDs and document fields intact.
  ///
  /// Container moves, concurrent creations and media changes require a
  /// causally ordered rebase because deleting a page may free asset bytes.
  static bool _independentPageDelete(
    OperationEnvelope removed,
    OperationEnvelope other,
  ) {
    if (removed.objectId == null) {
      return false;
    }
    if (other.kind == OperationKind.documentSet) {
      return true;
    }
    if (other.kind == OperationKind.objectMove) {
      return _moveAvoidsPage(other, removed.objectId!);
    }
    if (other.kind == OperationKind.pageSet) {
      return other.objectId != removed.objectId;
    }
    const independentObjects = {
      OperationKind.strokeCreate,
      OperationKind.objectSet,
      OperationKind.objectTransform,
      OperationKind.objectReorder,
      OperationKind.textInsert,
      OperationKind.textDelete,
      OperationKind.textFormat,
    };
    final assets = _assetIds(other);
    return other.pageId != null &&
        other.pageId != removed.objectId &&
        independentObjects.contains(other.kind) &&
        assets != null &&
        assets.isEmpty;
  }

  /// A page lifecycle change cannot affect a move between other pages.
  /// Moves touching the created/deleted page still require causal rebase.
  static bool _moveAvoidsPage(OperationEnvelope move, String pageId) {
    final destinationId = move.payload['toPageId'];
    return move.objectId != null &&
        move.pageId != null &&
        move.pageId != pageId &&
        destinationId is String &&
        destinationId.isNotEmpty &&
        destinationId != pageId;
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
      return _rankResolvedMetadata(remote, local);
    }
    return false;
  }

  /// A reorder-only move within the same page cannot invalidate the
  /// container of a pending scalar edit or Quill atom operation.
  ///
  /// Cross-page moves always require a causal rebase: the original
  /// operation's pageId must not be silently treated as its new page.
  static bool _independentSamePageMove(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    final move = remote.kind == OperationKind.objectMove
        ? remote
        : local.kind == OperationKind.objectMove
        ? local
        : null;
    if (move == null || move.pageId == null) {
      return false;
    }
    final edit = identical(move, remote) ? local : remote;
    if (edit.pageId != move.pageId ||
        move.payload['toPageId'] != move.pageId) {
      return false;
    }
    switch (edit.kind) {
      case OperationKind.objectSet:
      case OperationKind.objectTransform:
      case OperationKind.objectReorder:
        return _supportedObjectFields(edit);
      case OperationKind.textInsert:
      case OperationKind.textDelete:
      case OperationKind.textFormat:
        // The Quill reducer only touches atoms of this existing block.
        // Invalid atoms and anchors are still rejected by the reducer.
        return true;
      default:
        return false;
    }
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
        _supportedObjectFields(remote) &&
        _supportedObjectFields(local) &&
        (_disjointPropertyNames(remote, local) ||
            _rankResolvedObjectFields(remote, local));
  }

  /// Never let snapshot-like fields masquerade as independent updates.
  ///
  /// Valid reducers only accept bounded ink, image or text geometry keys.
  static bool _supportedObjectFields(OperationEnvelope operation) {
    final accepted = switch (operation.kind) {
      OperationKind.objectSet => const {
        'colorValue',
        'width',
        'height',
        'fontSize',
        'rotation',
        'dx',
        'dy',
        'sortIndex',
        'toolIndex',
        'cropLeft',
        'cropTop',
        'cropRight',
        'cropBottom',
      },
      OperationKind.objectTransform => const {
        'points',
        'dx',
        'dy',
        'width',
        'height',
        'rotation',
        'cropLeft',
        'cropTop',
        'cropRight',
        'cropBottom',
      },
      OperationKind.objectReorder => const {'sortIndex'},
      _ => const <String>{},
    };
    return _boundedScalarFields(operation, accepted);
  }

  /// Metadata field versions are durable on both projections.
  ///
  /// A later rank wins for the *same* field, regardless of arrival order.
  /// Only verified page and notebook metadata are covered here.
  static bool _rankResolvedMetadata(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    if (remote.kind != local.kind) {
      return false;
    }
    final fields = remote.kind == OperationKind.documentSet
        ? const {'title', 'folder'}
        : remote.kind == OperationKind.pageSet
        ? const {'title', 'isBookmarked'}
        : const <String>{};
    return _boundedScalarFields(remote, fields) &&
        _boundedScalarFields(local, fields);
  }

  /// Overlapping object scalar writes use the same per-field LWW register.
  ///
  /// Exclude assetId, crops and multi-field image transforms: they can
  /// depend on verified bytes, geometry or the current container. A stroke
  /// points update is one immutable register, ranked like other fields.
  static bool _rankResolvedObjectFields(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    if (remote.kind != local.kind) {
      return false;
    }
    final fields = switch (remote.kind) {
      OperationKind.objectSet => const {
        'colorValue',
        'width',
        'height',
        'fontSize',
        'rotation',
        'dx',
        'dy',
        'sortIndex',
        'toolIndex',
      },
      OperationKind.objectReorder => const {'sortIndex'},
      OperationKind.objectTransform => const {'points'},
      _ => const <String>{},
    };
    return _boundedScalarFields(remote, fields) &&
        _boundedScalarFields(local, fields);
  }

  static bool _boundedScalarFields(
    OperationEnvelope operation,
    Set<String> allowed,
  ) {
    final raw = operation.payload['properties'];
    return raw is Map &&
        raw.isNotEmpty &&
        raw.keys.every(allowed.contains) &&
        !raw.containsKey('assetId');
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

  /// Quill atoms and the text box geometry occupy different SQLite fields.
  static bool _independentTextAndGeometry(
    OperationEnvelope remote,
    OperationEnvelope local,
  ) {
    if (remote.pageId != local.pageId) {
      return false;
    }
    const textKinds = {
      OperationKind.textInsert,
      OperationKind.textDelete,
      OperationKind.textFormat,
    };
    final textRemote = textKinds.contains(remote.kind);
    if (textRemote == textKinds.contains(local.kind)) {
      return false;
    }
    final geometry = textRemote ? local : remote;
    // The v2 SQLite text reducer supports geometry via object.set only.
    // object.transform/reorder target ink and images, not text blocks.
    if (geometry.kind != OperationKind.objectSet) {
      return false;
    }
    final properties = geometry.payload['properties'];
    const safeFields = {
      'fontSize',
      'colorValue',
      'width',
      'rotation',
      'dx',
      'dy',
      'sortIndex',
    };
    return properties is Map &&
        properties.isNotEmpty &&
        properties.keys.every(safeFields.contains);
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
      // Same atom + attribute has an explicit rank in both CRDT reducers.
      // Deletes and insert anchors remain subject to the stricter checks.
      return first is Map &&
          second is Map &&
          first.isNotEmpty &&
          second.isNotEmpty;
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
    if (operation.kind == OperationKind.objectCreate) {
      final value = operation.payload['value'];
      if (value is Map && value['objectType'] == 'image') {
        final id = value['assetId'];
        if (id is! String) {
          return null;
        }
        ids.add(id);
      }
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
