import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';

import '../drift/notes_database.dart';
import 'operation_protocol.dart';
import 'operation_store.dart';
import 'operation_text_sequence.dart';
import 'share_ink_edit_adapter.dart';

/// Applies v2 page and ink operations to the production Drift tables.
///
/// Use only as the projection callback of OperationStore/SyncEngine, with
/// [database] identical to the store's database. No legacy saveNotebook
/// writer may mutate the same document while this projector is active.
///
/// Media, cross-page moves and document creation deliberately fail closed
/// until their durable projection is implemented. Quill embeds require a
/// verified asset store and are refused here. This is not a cutover switch.
class EditorSqliteProjector {
  EditorSqliteProjector(this.database)
      : _store = OperationStore(database);

  final NotesDatabase database;
  final OperationStore _store;
  final ShareInkEditAdapter _ink = ShareInkEditAdapter();

  Future<void> apply(OperationEnvelope operation) async {
    operation.validateForV2Projection();
    final document = await _row(
      'SELECT uid FROM notebook_rows WHERE uid = ?',
      [Variable<String>(operation.documentId)],
    );
    if (document == null) {
      throw StateError('The target notebook must be imported first.');
    }
    switch (operation.kind) {
      case OperationKind.pageCreate:
        await _createPage(operation);
      case OperationKind.pageSet:
        await _setPage(operation);
      case OperationKind.pageDelete:
        await _deletePage(operation);
      case OperationKind.strokeCreate:
        await _createStroke(operation);
      case OperationKind.objectCreate:
        await _createText(operation);
      case OperationKind.objectSet:
        if (await _textRow(operation) != null) {
          await _setText(operation);
        } else if (await _imageRow(operation) != null) {
          await _updateImage(operation);
        } else {
          await _updateStroke(operation);
        }
      case OperationKind.objectMove:
        await _moveObject(operation);
      case OperationKind.objectTransform:
      case OperationKind.objectReorder:
        if (await _imageRow(operation) != null) {
          await _updateImage(operation);
        } else {
          await _updateStroke(operation);
        }
      case OperationKind.textInsert:
      case OperationKind.textDelete:
      case OperationKind.textFormat:
        await _applyText(operation);
      case OperationKind.objectDelete:
        await _deleteObject(operation);
      default:
        throw UnsupportedError(
          'No verified SQLite editor reducer for ${operation.kind.wireName}.',
        );
    }
  }

  /// Resolves field-wise conflicts by the same deterministic v2 rank
  /// used by the server projector, independent of REST delivery order.
  ///
  /// The un-compacted operation journal owns the previous field versions.
  /// A future materialized version register can replace this replay safely.
  Future<Map<String, dynamic>> _winningProperties(
    OperationEnvelope operation,
    Map<String, dynamic> changes,
  ) async {
    if (changes.isEmpty) {
      return const {};
    }
    final pageTarget = operation.kind.target == OperationTarget.page;
    final kinds = pageTarget
        ? "('page.create', 'page.set')"
        : "('stroke.create', 'object.create', 'object.set', "
            "'object.transform', 'object.reorder', 'object.move')";
    final rows = await database.customSelect(
      'SELECT envelope_json FROM operations '
      'WHERE document_id = ? AND object_id = ? AND kind IN $kinds',
      variables: [
        Variable<String>(operation.documentId),
        Variable<String>(operation.objectId!),
      ],
    ).get();
    if (rows.length > 50000) {
      throw StateError('Field versions require a durable checkpoint.');
    }
    final losing = <String>{};
    for (final row in rows) {
      final raw = jsonDecode(row.read<String>('envelope_json'));
      if (raw is! Map) {
        throw const FormatException('Corrupt operation version envelope.');
      }
      final previous = OperationEnvelope.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (_compareRank(previous, operation) < 0) {
        continue;
      }
      final fields = switch (previous.kind) {
        OperationKind.pageCreate ||
        OperationKind.objectCreate ||
        OperationKind.strokeCreate => previous.payload['value'],
        OperationKind.pageSet ||
        OperationKind.objectSet ||
        OperationKind.objectTransform ||
        OperationKind.objectReorder => previous.payload['properties'],
        OperationKind.objectMove => {
          'sortIndex': previous.payload['sortIndex'],
        },
        _ => null,
      };
      if (fields is! Map) {
        continue;
      }
      for (final field in changes.keys) {
        if (fields.containsKey(field)) {
          losing.add(field);
        }
      }
    }
    return {
      for (final entry in changes.entries)
        if (!losing.contains(entry.key)) entry.key: entry.value,
    };
  }

  static int _compareRank(
    OperationEnvelope left,
    OperationEnvelope right,
  ) {
    final clock = left.logicalClock.compareTo(right.logicalClock);
    if (clock != 0) {
      return clock;
    }
    final actor = left.actorId.compareTo(right.actorId);
    if (actor != 0) {
      return actor;
    }
    final sequence = left.actorSeq.compareTo(right.actorSeq);
    if (sequence != 0) {
      return sequence;
    }
    return left.operationId.compareTo(right.operationId);
  }

  Future<Map<String, dynamic>?> _row(
    String statement,
    List<Variable> variables,
  ) async {
    final result = await database
        .customSelect(statement, variables: variables)
        .getSingleOrNull();
    return result?.data;
  }

  Future<void> _pageExists(OperationEnvelope op, String pageId) async {
    final page = await _row(
      'SELECT uid FROM page_rows WHERE uid = ? AND notebook_uid = ?',
      [Variable<String>(pageId), Variable<String>(op.documentId)],
    );
    if (page == null) {
      throw StateError('Page is missing or belongs to another notebook.');
    }
  }

  Future<void> _createPage(OperationEnvelope op) async {
    final id = op.objectId!;
    final value = Map<String, dynamic>.from(op.payload['value'] as Map);
    if (value.keys.any(
          (key) => key != 'title' && key != 'isBookmarked',
        ) ||
        value['title'] is! String ||
        value['isBookmarked'] is! bool) {
      throw const FormatException('Invalid page creation properties.');
    }
    final existing = await _row(
      'SELECT uid FROM page_rows WHERE uid = ?',
      [Variable<String>(id)],
    );
    if (existing != null) {
      throw StateError('Page identity is already in use.');
    }
    await database.customStatement(
      'INSERT INTO page_rows '
      '(uid, notebook_uid, page_index, title, is_bookmarked) '
      'SELECT ?, ?, COALESCE(MAX(page_index), -1) + 1, ?, ? '
      'FROM page_rows WHERE notebook_uid = ?',
      [
        id,
        op.documentId,
        value['title'],
        (value['isBookmarked'] as bool) ? 1 : 0,
        op.documentId,
      ],
    );
  }

  Future<void> _setPage(OperationEnvelope op) async {
    final id = op.objectId!;
    await _pageExists(op, id);
    var changes = Map<String, dynamic>.from(
      op.payload['properties'] as Map,
    );
    if (changes.isEmpty ||
        changes.keys.any(
          (key) => key != 'title' && key != 'isBookmarked',
        ) ||
        (changes.containsKey('title') &&
            changes['title'] is! String) ||
        (changes.containsKey('isBookmarked') &&
            changes['isBookmarked'] is! bool)) {
      throw const FormatException('Invalid page update properties.');
    }
    changes = await _winningProperties(op, changes);
    if (changes.isEmpty) {
      return;
    }
    final columns = <String>[];
    final values = <Object>[];
    if (changes.containsKey('title')) {
      columns.add('title = ?');
      values.add(changes['title'] as String);
    }
    if (changes.containsKey('isBookmarked')) {
      columns.add('is_bookmarked = ?');
      values.add((changes['isBookmarked'] as bool) ? 1 : 0);
    }
    if (columns.isEmpty) {
      throw const FormatException('Empty page update.');
    }
    await database.customStatement(
      'UPDATE page_rows SET ${columns.join(', ')} '
      'WHERE uid = ? AND notebook_uid = ?',
      [...values, id, op.documentId],
    );
  }

  Future<void> _deletePage(OperationEnvelope op) async {
    final pageId = op.objectId!;
    await _pageExists(op, pageId);
    final count = await _row(
      'SELECT COUNT(*) AS total FROM page_rows WHERE notebook_uid = ?',
      [Variable<String>(op.documentId)],
    );
    if ((count?['total'] as int? ?? 0) <= 1) {
      throw StateError('The last notebook page cannot be deleted.');
    }
    final images = await _row(
      'SELECT COUNT(*) AS total FROM image_block_rows WHERE page_uid = ?',
      [Variable<String>(pageId)],
    );
    if ((images?['total'] as int? ?? 0) > 0) {
      throw UnsupportedError(
        'Pages containing images/PDFs require verified asset detachment.',
      );
    }
    final assetPrefix = 'page:[${jsonEncode(pageId)},';
    final attached = await _row(
      'SELECT asset_id FROM asset_references '
      'WHERE document_id = ? AND substr(object_id, 1, ?) = ? LIMIT 1',
      [
        Variable<String>(op.documentId),
        Variable<int>(assetPrefix.length),
        Variable<String>(assetPrefix),
      ],
    );
    if (attached != null) {
      throw UnsupportedError(
        'Page still has durable asset references requiring detach.',
      );
    }
    // A legacy Quill embed is not necessarily stored as an image row.
    // Never discard its reference before the asset projector is available.
    final textRows = await database.customSelect(
      'SELECT delta_json FROM text_block_rows WHERE page_uid = ? '
      'AND delta_json IS NOT NULL',
      variables: [Variable<String>(pageId)],
    ).get();
    for (final row in textRows) {
      final decoded = jsonDecode(row.read<String>('delta_json'));
      if (decoded is! List) {
        throw const FormatException('Invalid stored Quill Delta.');
      }
      if (decoded.any(
        (entry) => entry is Map && entry['insert'] is Map,
      )) {
        throw UnsupportedError(
          'Quill embedded assets require verified asset detachment.',
        );
      }
    }
    for (final table in [
      'ink_stroke_rows',
      'text_block_rows',
      'image_block_rows',
    ]) {
      await database.customStatement(
        'DELETE FROM $table WHERE page_uid = ?',
        [pageId],
      );
    }
    await database.customStatement(
      'DELETE FROM page_rows WHERE uid = ? AND notebook_uid = ?',
      [pageId, op.documentId],
    );
  }

  Future<void> _objectIdUnused(String objectId) async {
    final found = await _row(
      'SELECT uid FROM ink_stroke_rows WHERE uid = ? '
      'UNION ALL SELECT uid FROM text_block_rows WHERE uid = ? '
      'UNION ALL SELECT uid FROM image_block_rows WHERE uid = ? '
      'LIMIT 1',
      [
        Variable<String>(objectId),
        Variable<String>(objectId),
        Variable<String>(objectId),
      ],
    );
    if (found != null) {
      throw StateError('Object identity already exists in SQLite.');
    }
  }

  Future<void> _createStroke(OperationEnvelope op) async {
    final pageId = op.pageId!;
    final objectId = op.objectId!;
    await _pageExists(op, pageId);
    await _objectIdUnused(objectId);
    final fields = Map<String, dynamic>.from(
      op.payload['value'] as Map,
    );
    if (fields['objectType'] != 'stroke' ||
        fields.keys.any(
          (key) => !const {
            'objectType',
            'colorValue',
            'width',
            'toolIndex',
            'sortIndex',
            'points',
          }.contains(key),
        )) {
      throw const FormatException('Unexpected ink creation properties.');
    }
    final stroke = _ink.decode(objectId, {
      'type': OperationKind.strokeCreate.wireName,
      'properties': fields,
    });
    final index = _index(fields['sortIndex']);
    await database.customStatement(
      'INSERT INTO ink_stroke_rows '
      '(uid, page_uid, color_value, width, tool_index, '
      'points_json, sort_index) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        objectId,
        pageId,
        stroke.color.toARGB32(),
        stroke.width,
        stroke.tool.index,
        _pointsJson(fields['points'] as List),
        index,
      ],
    );
  }

  /// Moves a verified object without reusing or tombstoning its ID.
  ///
  /// Text moves require a cross-page CRDT checkpoint and remain unsupported.
  Future<void> _moveObject(OperationEnvelope op) async {
    final sourceId = op.pageId!;
    final destinationId = op.payload['toPageId'] as String;
    final index = _index(op.payload['sortIndex']);
    await _pageExists(op, sourceId);
    await _pageExists(op, destinationId);
    if (await _store.isTombstoned(
      op.documentId,
      'page',
      destinationId,
    )) {
      throw StateError('Destination page has been tombstoned.');
    }
    final ink = await _row(
      'SELECT uid FROM ink_stroke_rows WHERE uid = ? AND page_uid = ?',
      [Variable<String>(op.objectId!), Variable<String>(sourceId)],
    );
    final image = await _imageRow(op);
    final text = await _textRow(op);
    final matches = (ink == null ? 0 : 1) +
        (image == null ? 0 : 1) +
        (text == null ? 0 : 1);
    if (matches != 1) {
      throw StateError('Missing or ambiguous move source.');
    }
    // A matching identity in a different page/layer must not be overwritten.
    final conflicting = await _row(
      'SELECT uid FROM ink_stroke_rows '
      'WHERE uid = ? AND page_uid != ? '
      'UNION ALL SELECT uid FROM image_block_rows '
      'WHERE uid = ? AND page_uid != ? '
      'UNION ALL SELECT uid FROM text_block_rows '
      'WHERE uid = ? AND page_uid != ? LIMIT 1',
      [
        Variable<String>(op.objectId!),
        Variable<String>(sourceId),
        Variable<String>(op.objectId!),
        Variable<String>(sourceId),
        Variable<String>(op.objectId!),
        Variable<String>(sourceId),
      ],
    );
    if (conflicting != null) {
      throw StateError('Move target identity is already occupied.');
    }
    if (text != null) {
      throw UnsupportedError('Text moves need cross-page CRDT history.');
    }

    final sourceAssetKey = 'page:${jsonEncode([sourceId, op.objectId])}';
    final destinationAssetKey =
        'page:${jsonEncode([destinationId, op.objectId])}';
    final linked = await database.customSelect(
      'SELECT asset_id FROM asset_references '
      'WHERE document_id = ? AND object_id = ?',
      variables: [
        Variable<String>(op.documentId),
        Variable<String>(sourceAssetKey),
      ],
    ).get();
    if (ink != null && linked.isNotEmpty) {
      throw UnsupportedError('Ink cannot move with attached media assets.');
    }
    if (image != null && linked.isEmpty) {
      throw UnsupportedError(
        'Image moves require durable scoped asset references.',
      );
    }
    if (image != null) {
      final destinationRefs = await _row(
        'SELECT asset_id FROM asset_references '
        'WHERE document_id = ? AND object_id = ? LIMIT 1',
        [
          Variable<String>(op.documentId),
          Variable<String>(destinationAssetKey),
        ],
      );
      if (destinationRefs != null) {
        throw StateError('Destination already owns asset references.');
      }
      await database.customStatement(
        'UPDATE asset_references SET object_id = ? '
        'WHERE document_id = ? AND object_id = ?',
        [destinationAssetKey, op.documentId, sourceAssetKey],
      );
    }
    final table = ink != null ? 'ink_stroke_rows' : 'image_block_rows';
    await database.customStatement(
      'UPDATE $table SET page_uid = ?, sort_index = ? '
      'WHERE uid = ? AND page_uid = ?',
      [destinationId, index, op.objectId, sourceId],
    );
  }

  Future<Map<String, dynamic>> _storedStroke(
    OperationEnvelope op,
  ) async {
    await _pageExists(op, op.pageId!);
    final row = await _row(
      'SELECT color_value, width, tool_index, points_json, sort_index '
      'FROM ink_stroke_rows WHERE uid = ? AND page_uid = ?',
      [Variable<String>(op.objectId!), Variable<String>(op.pageId!)],
    );
    if (row == null) {
      throw StateError('Ink target does not exist on this page.');
    }
    final decoded = jsonDecode(row['points_json'] as String);
    if (decoded is! List ||
        decoded.any(
          (point) =>
              point is! Map ||
              point['dx'] is! num ||
              point['dy'] is! num ||
              point['pressure'] is! num,
        )) {
      throw const FormatException('Corrupt persisted ink points.');
    }
    return {
      'colorValue': row['color_value'],
      'width': row['width'],
      'toolIndex': row['tool_index'],
      'sortIndex': row['sort_index'],
      'points': [
        for (final point in decoded)
          [point['dx'], point['dy'], point['pressure']],
      ],
    };
  }

  Future<void> _updateStroke(OperationEnvelope op) async {
    final before = await _storedStroke(op);
    var changes = Map<String, dynamic>.from(
      op.payload['properties'] as Map,
    );
    final allowed = switch (op.kind) {
      OperationKind.objectTransform => {'points'},
      OperationKind.objectReorder => {'sortIndex'},
      _ => {'colorValue', 'width', 'toolIndex'},
    };
    if (changes.isEmpty ||
        changes.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unsupported ink update property.');
    }
    changes = await _winningProperties(op, changes);
    if (changes.isEmpty) {
      return;
    }
    final merged = {...before, ...changes};
    final stroke = _ink.decode(op.objectId!, {
      'type': OperationKind.strokeCreate.wireName,
      'properties': merged,
    });
    final index = _index(merged['sortIndex']);
    await database.customStatement(
      'UPDATE ink_stroke_rows SET color_value = ?, width = ?, '
      'tool_index = ?, points_json = ?, sort_index = ? '
      'WHERE uid = ? AND page_uid = ?',
      [
        stroke.color.toARGB32(),
        stroke.width,
        stroke.tool.index,
        _pointsJson(merged['points'] as List),
        index,
        op.objectId,
        op.pageId,
      ],
    );
  }

  Future<void> _deleteObject(OperationEnvelope op) async {
    await _pageExists(op, op.pageId!);
    final ink = await _row(
      'SELECT uid FROM ink_stroke_rows WHERE uid = ? AND page_uid = ?',
      [Variable<String>(op.objectId!), Variable<String>(op.pageId!)],
    );
    final text = await _textRow(op);
    final image = await _row(
      'SELECT uid FROM image_block_rows WHERE uid = ? AND page_uid = ?',
      [Variable<String>(op.objectId!), Variable<String>(op.pageId!)],
    );
    final matches = (ink == null ? 0 : 1) +
        (text == null ? 0 : 1) +
        (image == null ? 0 : 1);
    if (matches != 1) {
      throw StateError('Missing or ambiguous editor object identity.');
    }
    if (image != null) {
      throw UnsupportedError('Image deletion requires asset detachment.');
    }
    await database.customStatement(
      ink != null
          ? 'DELETE FROM ink_stroke_rows WHERE uid = ? AND page_uid = ?'
          : 'DELETE FROM text_block_rows WHERE uid = ? AND page_uid = ?',
      [op.objectId, op.pageId],
    );
  }

  Future<Map<String, dynamic>?> _imageRow(OperationEnvelope op) => _row(
    'SELECT dx, dy, width, height, rotation, crop_left, crop_top, '
    'crop_right, crop_bottom, sort_index FROM image_block_rows '
    'WHERE uid = ? AND page_uid = ?',
    [Variable<String>(op.objectId!), Variable<String>(op.pageId!)],
  );

  /// Only geometry and z-order may change; asset content never changes here.
  Future<void> _updateImage(OperationEnvelope op) async {
    await _pageExists(op, op.pageId!);
    final row = await _imageRow(op);
    if (row == null) {
      throw StateError('Missing image object.');
    }
    var changes = Map<String, dynamic>.from(
      op.payload['properties'] as Map,
    );
    final allowed = <String, String>{
      'dx': 'dx',
      'dy': 'dy',
      'width': 'width',
      'height': 'height',
      'rotation': 'rotation',
      'cropLeft': 'crop_left',
      'cropTop': 'crop_top',
      'cropRight': 'crop_right',
      'cropBottom': 'crop_bottom',
      'sortIndex': 'sort_index',
    };
    if (changes.isEmpty ||
        changes.keys.any((key) => !allowed.containsKey(key))) {
      throw const FormatException('Unsupported image geometry properties.');
    }
    for (final entry in changes.entries) {
      if (entry.key == 'sortIndex') {
        _index(entry.value);
      } else if (entry.value is! num ||
          !(entry.value as num).toDouble().isFinite ||
          (const {'width', 'height'}.contains(entry.key) &&
              (entry.value as num) <= 0) ||
          (entry.key.startsWith('crop') &&
              ((entry.value as num) < 0 || (entry.value as num) > 1))) {
        throw const FormatException('Invalid image geometry.');
      }
    }
    changes = await _winningProperties(op, changes);
    if (changes.isEmpty) {
      return;
    }
    final updates = [
      for (final key in changes.keys) '${allowed[key]} = ?',
    ];
    await database.customStatement(
      'UPDATE image_block_rows SET ${updates.join(', ')} '
      'WHERE uid = ? AND page_uid = ?',
      [
        for (final entry in changes.entries) entry.value,
        op.objectId,
        op.pageId,
      ],
    );
  }

  Future<Map<String, dynamic>?> _textRow(OperationEnvelope op) => _row(
    'SELECT text, delta_json, font_size, color_value, width, rotation, '
    'dx, dy, sort_index FROM text_block_rows '
    'WHERE uid = ? AND page_uid = ?',
    [Variable<String>(op.objectId!), Variable<String>(op.pageId!)],
  );

  Future<void> _createText(OperationEnvelope op) async {
    final pageId = op.pageId!;
    await _pageExists(op, pageId);
    await _objectIdUnused(op.objectId!);
    final value = Map<String, dynamic>.from(op.payload['value'] as Map);
    if (value['objectType'] != 'text') {
      throw UnsupportedError('Only text object.create is supported.');
    }
    final fields = Map<String, dynamic>.from(value)..remove('objectType');
    _validateTextGeometry(fields);
    await database.customStatement(
      'INSERT INTO text_block_rows '
      '(uid, page_uid, text, delta_json, font_size, color_value, '
      'width, rotation, dx, dy, sort_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        op.objectId,
        pageId,
        '',
        null,
        (fields['fontSize'] as num).toDouble(),
        fields['colorValue'],
        (fields['width'] as num).toDouble(),
        (fields['rotation'] as num).toDouble(),
        (fields['dx'] as num).toDouble(),
        (fields['dy'] as num).toDouble(),
        fields['sortIndex'],
      ],
    );
  }

  Future<void> _setText(OperationEnvelope op) async {
    await _pageExists(op, op.pageId!);
    final row = await _textRow(op);
    if (row == null) {
      throw StateError('Missing text object.');
    }
    var changes = Map<String, dynamic>.from(
      op.payload['properties'] as Map,
    );
    if (changes.isEmpty || changes.keys.any(
      (key) => !const {
        'fontSize',
        'colorValue',
        'width',
        'rotation',
        'dx',
        'dy',
        'sortIndex',
      }.contains(key),
    )) {
      throw const FormatException('Unsupported text property update.');
    }
    final merged = <String, dynamic>{
      'fontSize': row['font_size'],
      'colorValue': row['color_value'],
      'width': row['width'],
      'rotation': row['rotation'],
      'dx': row['dx'],
      'dy': row['dy'],
      'sortIndex': row['sort_index'],
      ...changes,
    };
    _validateTextGeometry(merged);
    changes = await _winningProperties(op, changes);
    if (changes.isEmpty) {
      return;
    }
    for (final field in const {
      'fontSize': 'font_size',
      'colorValue': 'color_value',
      'width': 'width',
      'rotation': 'rotation',
      'dx': 'dx',
      'dy': 'dy',
      'sortIndex': 'sort_index',
    }.entries) {
      if (!changes.containsKey(field.key)) {
        merged[field.key] = row[field.value];
      }
    }
    await database.customStatement(
      'UPDATE text_block_rows SET font_size = ?, color_value = ?, '
      'width = ?, rotation = ?, dx = ?, dy = ?, sort_index = ? '
      'WHERE uid = ? AND page_uid = ?',
      [
        (merged['fontSize'] as num).toDouble(),
        merged['colorValue'],
        (merged['width'] as num).toDouble(),
        (merged['rotation'] as num).toDouble(),
        (merged['dx'] as num).toDouble(),
        (merged['dy'] as num).toDouble(),
        merged['sortIndex'],
        op.objectId,
        op.pageId,
      ],
    );
  }

  Future<void> _applyText(OperationEnvelope op) async {
    await _pageExists(op, op.pageId!);
    final row = await _textRow(op);
    if (row == null) {
      throw StateError('Text CRDT operation requires a text object.');
    }
    if (op.kind == OperationKind.textInsert) {
      for (final atom in op.payload['atoms'] as List) {
        if ((atom as Map).containsKey('embed')) {
          throw UnsupportedError('Quill embeds require an asset projector.');
        }
      }
    }
    final durable = await _store.textAtoms(
      documentId: op.documentId,
      pageId: op.pageId!,
      objectId: op.objectId!,
    );
    final previousText = OperationTextSequence.render(durable).trimRight();
    if (row['text'] != previousText) {
      throw StateError('The text projection is not at its durable frontier.');
    }
    final storedDelta = row['delta_json'];
    final durableDelta = OperationTextSequence.renderDelta(durable);
    if ((storedDelta == null && durable.isNotEmpty) ||
        (storedDelta != null &&
            !const DeepCollectionEquality().equals(
              jsonDecode(storedDelta as String),
              durableDelta,
            ))) {
      throw StateError('The Quill Delta differs from the durable atoms.');
    }
    final updated = OperationTextSequence.apply(durable, op);
    final text = OperationTextSequence.render(updated).trimRight();
    await database.customStatement(
      'UPDATE text_block_rows SET text = ?, delta_json = ? '
      'WHERE uid = ? AND page_uid = ?',
      [
        text,
        jsonEncode(OperationTextSequence.renderDelta(updated)),
        op.objectId,
        op.pageId,
      ],
    );
  }

  static void _validateTextGeometry(Map<String, dynamic> fields) {
    if (fields.keys.length != 7 ||
        fields.keys.any(
          (key) => !const {
            'fontSize',
            'colorValue',
            'width',
            'rotation',
            'dx',
            'dy',
            'sortIndex',
          }.contains(key),
        ) ||
        fields['colorValue'] is! int ||
        (fields['colorValue'] as int) < 0 ||
        (fields['colorValue'] as int) > 0xFFFFFFFF) {
      throw const FormatException('Invalid text geometry.');
    }
    for (final key in ['fontSize', 'width', 'rotation', 'dx', 'dy']) {
      final value = fields[key];
      if (value is! num || !value.toDouble().isFinite ||
          (const {'fontSize', 'width'}.contains(key) && value <= 0)) {
        throw const FormatException('Invalid text geometry.');
      }
    }
    _index(fields['sortIndex']);
  }

  static int _index(Object? value) {
    if (value is! int || value < 0 || value >= 1000000) {
      throw const FormatException('Invalid z-order index.');
    }
    return value;
  }

  static String _pointsJson(List points) => jsonEncode([
    for (final point in points)
      {
        'dx': point[0],
        'dy': point[1],
        'pressure': point[2],
      },
  ]);
}
