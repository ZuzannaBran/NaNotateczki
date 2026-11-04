import 'dart:convert';

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
        } else {
          await _updateStroke(operation);
        }
      case OperationKind.objectTransform:
      case OperationKind.objectReorder:
        await _updateStroke(operation);
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
    final changes = Map<String, dynamic>.from(
      op.payload['properties'] as Map,
    );
    if (changes.keys.any(
          (key) => key != 'title' && key != 'isBookmarked',
        ) ||
        (changes.containsKey('title') &&
            changes['title'] is! String) ||
        (changes.containsKey('isBookmarked') &&
            changes['isBookmarked'] is! bool)) {
      throw const FormatException('Invalid page update properties.');
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
    final changes = Map<String, dynamic>.from(
      op.payload['properties'] as Map,
    );
    final allowed = switch (op.kind) {
      OperationKind.objectTransform => {'points'},
      OperationKind.objectReorder => {'sortIndex'},
      _ => {'colorValue', 'width', 'toolIndex'},
    };
    if (changes.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unsupported ink update property.');
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
    if (ink != null) {
      await database.customStatement(
        'DELETE FROM ink_stroke_rows WHERE uid = ? AND page_uid = ?',
        [op.objectId, op.pageId],
      );
      return;
    }
    if (await _textRow(op) != null) {
      await database.customStatement(
        'DELETE FROM text_block_rows WHERE uid = ? AND page_uid = ?',
        [op.objectId, op.pageId],
      );
      return;
    }
    throw StateError('Unsupported or missing object deletion target.');
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
    final changes = Map<String, dynamic>.from(
      op.payload['properties'] as Map,
    );
    if (changes.keys.any(
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
