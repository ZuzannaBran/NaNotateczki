import 'dart:convert';

/// The v1 wire-format namespace shared by account sync and study shares.
enum OperationTarget { document, page, object, folder, task }

enum OperationKind {
  documentCreate('document.create', OperationTarget.document),
  documentSet('document.set', OperationTarget.document),
  documentDelete('document.delete', OperationTarget.document),
  pageCreate('page.create', OperationTarget.page),
  pageSet('page.set', OperationTarget.page),
  pageDelete('page.delete', OperationTarget.page),
  strokeCreate('stroke.create', OperationTarget.object),
  objectCreate('object.create', OperationTarget.object),
  objectSet('object.set', OperationTarget.object),
  objectTransform('object.transform', OperationTarget.object),
  objectMove('object.move', OperationTarget.object),
  objectReorder('object.reorder', OperationTarget.object),
  objectDelete('object.delete', OperationTarget.object),
  textInsert('text.insert', OperationTarget.object),
  textDelete('text.delete', OperationTarget.object),
  textFormat('text.format', OperationTarget.object),
  assetAttach('asset.attach', OperationTarget.object),
  assetDetach('asset.detach', OperationTarget.object),
  folderCreate('folder.create', OperationTarget.folder),
  folderSet('folder.set', OperationTarget.folder),
  folderMove('folder.move', OperationTarget.folder),
  folderDelete('folder.delete', OperationTarget.folder),
  taskCreate('task.create', OperationTarget.task),
  taskSet('task.set', OperationTarget.task),
  taskMove('task.move', OperationTarget.task),
  taskDelete('task.delete', OperationTarget.task);

  const OperationKind(this.wireName, this.target);

  final String wireName;
  final OperationTarget target;

  static OperationKind parse(String value) {
    for (final kind in values) {
      if (kind.wireName == value) {
        return kind;
      }
    }
    throw FormatException('Unknown operation type: $value');
  }
}

/// A durable user intent, never a complete notebook or backup snapshot.
///
/// IDs are stable across retries. Inverse edits for undo/redo are new
/// operations, optionally carrying [revertsOperationId]. No view state is
/// serialized here.
class OperationEnvelope {
  OperationEnvelope({
    required this.operationId,
    required this.actorId,
    required this.actorSeq,
    required this.documentId,
    required this.kind,
    required Map<String, dynamic> payload,
    required List<String> dependencies,
    required this.logicalClock,
    this.objectId,
    this.pageId,
    this.revertsOperationId,
    this.schemaVersion = currentSchemaVersion,
  }) : payload = _immutablePayload(payload),
       dependencies = List.unmodifiable(dependencies) {
    _validate();
  }

  static const currentSchemaVersion = 1;
  static const maxSafeInteger = 9007199254740991;
  static const libraryDocumentId = '@library';
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static final RegExp _invalidIdentifierChar = RegExp(r'[\x00-\x1f\x7f]');

  static bool _isValidUuid(String value) =>
      value.length == 36 && _uuidPattern.hasMatch(value);

  final String operationId;
  final String actorId;
  final int actorSeq;
  final String documentId;
  final String? pageId;
  final String? objectId;
  final OperationKind kind;
  final Map<String, dynamic> payload;
  final List<String> dependencies;
  final int logicalClock;
  final String? revertsOperationId;
  final int schemaVersion;

  factory OperationEnvelope.fromJson(Map<String, dynamic> json) {
    return OperationEnvelope(
      operationId: json['operationId'] as String,
      actorId: json['actorId'] as String,
      actorSeq: json['actorSeq'] as int,
      documentId: json['documentId'] as String,
      pageId: json['pageId'] as String?,
      objectId: json['objectId'] as String?,
      kind: OperationKind.parse(json['type'] as String),
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      dependencies: List<String>.from(json['dependencies'] as List),
      logicalClock: json['logicalClock'] as int,
      revertsOperationId: json['revertsOperationId'] as String?,
      schemaVersion: json['schemaVersion'] as int,
    );
  }

  /// Validates payloads supported by the actual v2 PostgreSQL projector.
  ///
  /// Inline Quill embeds must use attached asset IDs. The projector verifies
  /// their presence and MIME before an atom becomes visible.
  void validateForV2Projection() {
    validateV2Payload(
      kind: kind,
      payload: payload,
      documentId: documentId,
      objectId: objectId,
      pageId: pageId,
    );
  }

  /// Validates an inline Quill image/PDF reference and returns its asset ID.
  ///
  /// Remote URLs and local file paths cannot be used as durable embed IDs.
  static String embedAssetId(Object? embed) {
    if (embed is! Map || embed.length != 1) {
      throw const FormatException('Invalid Quill embed.');
    }
    final kind = embed.keys.single;
    final reference = embed[kind];
    if ((kind != 'image' && kind != 'pdf') ||
        reference is! String ||
        !reference.startsWith('asset:')) {
      throw const FormatException('Quill embed must reference an asset.');
    }
    final id = reference.substring(6);
    if (id.isEmpty || id.length > 128 || _invalidIdentifierChar.hasMatch(id)) {
      throw const FormatException('Invalid Quill embed asset ID.');
    }
    return id;
  }

  static void validateV2Payload({
    required OperationKind kind,
    required Map<String, dynamic> payload,
    required String documentId,
    String? objectId,
    String? pageId,
  }) {
    if (kind == OperationKind.objectMove) {
      final destination = payload['toPageId'];
      final order = payload['sortIndex'];
      if (payload.length != 2 ||
          destination is! String ||
          destination.isEmpty ||
          destination.length > 128 ||
          _invalidIdentifierChar.hasMatch(destination) ||
          destination == pageId ||
          order is! int ||
          order < 0 ||
          order >= 1000000) {
        throw const FormatException('Invalid object.move payload.');
      }
      return;
    }
    if (kind == OperationKind.assetAttach) {
      final id = payload['assetId'];
      final checksum = payload['sha256'];
      final size = payload['sizeBytes'];
      final mime = payload['mediaType'];
      if (payload.length != 4 ||
          id is! String ||
          id.isEmpty ||
          id.length > 128 ||
          _invalidIdentifierChar.hasMatch(id) ||
          checksum is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum) ||
          size is! int ||
          size < 1 ||
          size > 64 * 1024 * 1024 ||
          mime is! String ||
          !const {
            'image/png',
            'image/jpeg',
            'image/webp',
            'application/pdf',
          }.contains(mime)) {
        throw const FormatException('Invalid asset.attach payload.');
      }
      return;
    }
    if (kind == OperationKind.assetDetach) {
      final id = payload['assetId'];
      if (payload.length != 1 ||
          id is! String ||
          id.isEmpty ||
          id.length > 128 ||
          _invalidIdentifierChar.hasMatch(id)) {
        throw const FormatException('Invalid asset.detach payload.');
      }
      return;
    }
    if (kind == OperationKind.textInsert) {
      final anchor = payload['afterAtomId'];
      final atoms = payload['atoms'];
      if (payload.length != 2 ||
          !payload.containsKey('afterAtomId') ||
          (anchor != null && (anchor is! String || !_isValidUuid(anchor))) ||
          atoms is! List ||
          atoms.isEmpty ||
          atoms.length > 256) {
        throw const FormatException('Invalid text.insert payload.');
      }
      final seen = <String>{};
      for (final atom in atoms) {
        if (atom is! Map ||
            (atom.length < 2 || atom.length > 4) ||
            atom.keys.any(
              (key) =>
                  key != 'id' &&
                  key != 'text' &&
                  key != 'attributes' &&
                  key != 'embed',
            ) ||
            !atom.containsKey('id') ||
            !atom.containsKey('text') ||
            atom['id'] is! String ||
            atom['text'] is! String ||
            !_isValidUuid(atom['id'] as String) ||
            !seen.add(atom['id'] as String) ||
            (atom['text'] as String).isEmpty ||
            (atom['text'] as String).runes.length > 1024) {
          throw const FormatException('Invalid text atom.');
        }
        if (atom.containsKey('attributes')) {
          _validateTextAttributes(atom['attributes']);
        }
        if (atom.containsKey('embed')) {
          if (atom['text'] != '\uFFFC') {
            throw const FormatException('Quill embed needs a single atom.');
          }
          embedAssetId(atom['embed']);
        } else if ((atom['text'] as String).contains('\uFFFC')) {
          throw const FormatException('Unlinked Quill replacement character.');
        }
      }
      return;
    }
    if (kind == OperationKind.textDelete) {
      final ids = payload['atomIds'];
      if (payload.length != 1 ||
          ids is! List ||
          ids.isEmpty ||
          ids.length > 256 ||
          ids.any((id) => id is! String || !_isValidUuid(id)) ||
          ids.toSet().length != ids.length) {
        throw const FormatException('Invalid text.delete payload.');
      }
      return;
    }
    if (kind == OperationKind.textFormat) {
      final ids = payload['atomIds'];
      final changes = payload['attributes'];
      if (payload.length != 2 ||
          !payload.containsKey('atomIds') ||
          !payload.containsKey('attributes') ||
          ids is! List ||
          ids.isEmpty ||
          ids.length > 256 ||
          ids.any((id) => id is! String || !_isValidUuid(id)) ||
          ids.toSet().length != ids.length ||
          changes is! Map ||
          changes.isEmpty) {
        throw const FormatException('Invalid text.format payload.');
      }
      _validateTextAttributes(changes, allowNull: true);
      return;
    }
    if (kind.wireName.endsWith('.delete')) {
      if (payload.isNotEmpty) {
        throw const FormatException('Delete payload must be empty.');
      }
      return;
    }
    final creating =
        kind == OperationKind.strokeCreate || kind.wireName.endsWith('.create');
    final fieldName = creating ? 'value' : 'properties';
    final value = payload[fieldName];
    if (value is! Map || payload.length != 1 || (!creating && value.isEmpty)) {
      throw FormatException('Expected exactly one $fieldName object.');
    }
    if (!creating &&
        (value.containsKey('id') ||
            value.containsKey('uid') ||
            (kind.target == OperationTarget.object &&
                (value.containsKey('objectType') ||
                    value.containsKey('textAtoms'))))) {
      throw const FormatException(
        'Identity and CRDT internals cannot be changed by property edits.',
      );
    }
    for (final key in value.keys) {
      if (key is! String || key.isEmpty || key.length > 128) {
        throw const FormatException('Invalid property name.');
      }
    }
    if (kind == OperationKind.taskCreate &&
        (value['plannerUid'] is! String ||
            (value['plannerUid'] as String).isEmpty)) {
      throw const FormatException('Task requires a plannerUid.');
    }
    if (kind.target == OperationTarget.task &&
        value.containsKey('plannerUid') &&
        (value['plannerUid'] is! String ||
            (value['plannerUid'] as String).isEmpty)) {
      throw const FormatException('Invalid task plannerUid.');
    }
    if (creating) {
      final targetId = objectId ?? documentId;
      if (value.containsKey('id') && value['id'] != targetId) {
        throw const FormatException('Create payload ID does not match target.');
      }
      if (value.containsKey('uid') && value['uid'] != documentId) {
        throw const FormatException(
          'Create payload UID does not match target.',
        );
      }
    }
  }

  static void _validateTextAttributes(
    Object? candidate, {
    bool allowNull = false,
  }) {
    if (candidate is! Map || candidate.length > 32) {
      throw const FormatException('Invalid Quill attributes.');
    }
    for (final entry in candidate.entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String || name.isEmpty || name.length > 64) {
        throw const FormatException('Invalid Quill attribute name.');
      }
      if (value == null && allowNull) {
        continue;
      }
      if (value is! String && value is! bool && value is! num) {
        throw const FormatException('Invalid Quill attribute value.');
      }
      if ((value is String && value.length > 2048) ||
          (value is num && !value.isFinite)) {
        throw const FormatException('Invalid Quill attribute value.');
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'operationId': operationId,
    'actorId': actorId,
    'actorSeq': actorSeq,
    'documentId': documentId,
    if (pageId != null) 'pageId': pageId,
    if (objectId != null) 'objectId': objectId,
    'type': kind.wireName,
    'payload': _copyPayload(),
    'dependencies': List<String>.of(dependencies),
    'logicalClock': logicalClock,
    if (revertsOperationId != null) 'revertsOperationId': revertsOperationId,
  };

  /// Return a defensive JSON copy so caller mutations cannot affect a replay.
  Map<String, dynamic> _copyPayload() =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map);

  static Map<String, dynamic> _immutablePayload(Map<String, dynamic> input) {
    try {
      final decoded = jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
      return Map<String, dynamic>.unmodifiable(
        decoded.map((key, value) => MapEntry(key, _freeze(value))),
      );
    } on Object {
      throw const FormatException('Payload must be valid JSON.');
    }
  }

  static Object? _freeze(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.unmodifiable(
        value.map((key, item) => MapEntry(key as String, _freeze(item))),
      );
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_freeze));
    }
    return value;
  }

  void _validate() {
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException('Unsupported operation schema: $schemaVersion');
    }
    if (!_isValidUuid(operationId) ||
        (revertsOperationId != null && !_isValidUuid(revertsOperationId!))) {
      throw const FormatException('Invalid operation UUID.');
    }
    if (actorId.isEmpty ||
        actorId.length > 128 ||
        documentId.isEmpty ||
        documentId.length > 128 ||
        actorSeq < 1 ||
        actorSeq > maxSafeInteger ||
        logicalClock < 1 ||
        logicalClock > maxSafeInteger) {
      throw const FormatException('Invalid actor, sequence, or clock.');
    }
    if (dependencies.length > 256 ||
        dependencies.toSet().length != dependencies.length ||
        dependencies.contains(operationId) ||
        dependencies.any((id) => !_isValidUuid(id)) ||
        (revertsOperationId != null &&
            !dependencies.contains(revertsOperationId))) {
      throw const FormatException('Invalid causal dependencies.');
    }
    if (_invalidIdentifierChar.hasMatch(actorId) ||
        _invalidIdentifierChar.hasMatch(documentId) ||
        (pageId != null &&
            (pageId!.length > 128 ||
                _invalidIdentifierChar.hasMatch(pageId!))) ||
        (objectId != null &&
            (objectId!.length > 128 ||
                _invalidIdentifierChar.hasMatch(objectId!)))) {
      throw const FormatException('Invalid target identifier.');
    }
    if (kind.target == OperationTarget.document &&
        (objectId != null || pageId != null)) {
      throw const FormatException('Document operations have no object ID.');
    }
    if (kind.target == OperationTarget.page &&
        (objectId == null || objectId!.isEmpty || pageId != null)) {
      throw const FormatException(
        'Page operations require the page object ID.',
      );
    }
    if (kind.target == OperationTarget.object &&
        (objectId == null ||
            objectId!.isEmpty ||
            pageId == null ||
            pageId!.isEmpty)) {
      throw const FormatException(
        'Object operations require page and object IDs.',
      );
    }
    if ((kind.target == OperationTarget.folder ||
            kind.target == OperationTarget.task) &&
        (documentId != libraryDocumentId ||
            objectId == null ||
            objectId!.isEmpty ||
            pageId != null)) {
      throw const FormatException('Library operations require an object ID.');
    }
    if (kind.target != OperationTarget.folder &&
        kind.target != OperationTarget.task &&
        documentId == libraryDocumentId) {
      throw const FormatException('Library namespace is reserved.');
    }
  }
}
