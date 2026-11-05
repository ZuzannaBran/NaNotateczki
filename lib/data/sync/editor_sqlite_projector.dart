import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';

import '../drift/notes_database.dart';
import 'operation_asset_gateway.dart';
import 'operation_protocol.dart';
import 'operation_store.dart';
import 'operation_text_sequence.dart';
import 'share_ink_edit_adapter.dart';
import 'verified_editor_asset_buffer.dart';

/// Applies v2 page and ink operations to the production Drift tables.
///
/// Use only as the projection callback of OperationStore/SyncEngine, with
/// [database] identical to the store's database. No legacy saveNotebook
/// writer may mutate the same document while this projector is active.
///
/// Quill media require verified durable bytes and scoped asset references.
/// Cross-page moves relocate those references in the same SQLite transaction.
/// This class does not enable the production protocol switch.
class EditorSqliteProjector {
  EditorSqliteProjector(this.database, {this.verifiedAssetBuffer})
    : _store = OperationStore(database);

  final NotesDatabase database;
  final VerifiedEditorAssetBuffer? verifiedAssetBuffer;
  final OperationStore _store;
  final ShareInkEditAdapter _ink = ShareInkEditAdapter();

  Future<void> apply(OperationEnvelope operation) async {
    operation.validateForV2Projection();
    if (operation.kind == OperationKind.documentCreate) {
      await _createDocument(operation);
      return;
    }
    final document = await _row('SELECT uid FROM notebook_rows WHERE uid = ?', [
      Variable<String>(operation.documentId),
    ]);
    if (document == null) {
      throw StateError('The target notebook must be imported first.');
    }
    switch (operation.kind) {
      case OperationKind.documentSet:
        await _setDocument(operation);
      case OperationKind.documentDelete:
        await _deleteDocument(operation);
        return;
      case OperationKind.pageCreate:
        await _createPage(operation);
      case OperationKind.pageSet:
        await _setPage(operation);
      case OperationKind.pageDelete:
        await _deletePage(operation);
      case OperationKind.strokeCreate:
        await _createStroke(operation);
      case OperationKind.objectCreate:
        await _createObject(operation);
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
      case OperationKind.assetAttach:
        await _attachVerifiedAsset(operation);
      case OperationKind.assetDetach:
        await _detachUnusedAsset(operation);
      default:
        throw UnsupportedError(
          'No verified SQLite editor reducer for ${operation.kind.wireName}.',
        );
    }
    await _touchNotebook(operation.documentId);
  }

  /// Creates a fresh operational document and its pages through one v2 batch.
  /// No legacy repository writer participates in the bootstrap.
  Future<void> _createDocument(OperationEnvelope op) async {
    final existing = await _row('SELECT uid FROM notebook_rows WHERE uid = ?', [
      Variable<String>(op.documentId),
    ]);
    if (existing != null) {
      throw StateError('V2 document creation cannot import a legacy row.');
    }
    final value = Map<String, dynamic>.from(op.payload['value'] as Map);
    if (value.length != 4 ||
        value['title'] is! String ||
        (value['title'] as String).isEmpty ||
        value['folder'] is! String ||
        (value['folder'] as String).isEmpty ||
        value['kindIndex'] is! int ||
        !const {0, 1}.contains(value['kindIndex']) ||
        value['createdAt'] is! String) {
      throw const FormatException('Invalid v2 notebook creation.');
    }
    final createdAt = DateTime.tryParse(value['createdAt'] as String);
    if (createdAt == null) {
      throw const FormatException('Invalid v2 notebook creation time.');
    }
    await database
        .into(database.notebookRows)
        .insert(
          NotebookRowsCompanion.insert(
            uid: op.documentId,
            title: value['title'] as String,
            kindIndex: value['kindIndex'] as int,
            folder: value['folder'] as String,
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
  }

  /// Deletes the entire document projection in one operation transaction.
  /// Tombstones and the immutable journal are retained by OperationStore.
  Future<void> _deleteDocument(OperationEnvelope op) async {
    for (final table in const [
      'ink_stroke_rows',
      'text_block_rows',
      'image_block_rows',
    ]) {
      await database.customStatement(
        'DELETE FROM $table WHERE page_uid IN '
        '(SELECT uid FROM page_rows WHERE notebook_uid = ?)',
        [op.documentId],
      );
    }
    await database.customStatement(
      'DELETE FROM asset_references WHERE document_id = ?',
      [op.documentId],
    );
    await database.customStatement(
      'DELETE FROM page_rows WHERE notebook_uid = ?',
      [op.documentId],
    );
    await database.customStatement('DELETE FROM notebook_rows WHERE uid = ?', [
      op.documentId,
    ]);
  }

  Future<void> _setDocument(OperationEnvelope op) async {
    final raw = Map<String, dynamic>.from(op.payload['properties'] as Map);
    if (raw.isEmpty ||
        raw.keys.any((key) => key != 'title' && key != 'folder') ||
        raw.values.any((value) => value is! String || value.isEmpty)) {
      throw const FormatException('Unsupported v2 notebook metadata edit.');
    }
    final changes = await _winningProperties(op, raw);
    if (changes.isEmpty) {
      return;
    }
    final notebook = await _row(
      'SELECT title, folder FROM notebook_rows WHERE uid = ?',
      [Variable<String>(op.documentId)],
    );
    if (notebook == null) {
      throw StateError('Cannot change a missing v2 notebook.');
    }
    await database.customStatement(
      'UPDATE notebook_rows SET title = ?, folder = ? WHERE uid = ?',
      [
        changes['title'] ?? notebook['title'],
        changes['folder'] ?? notebook['folder'],
        op.documentId,
      ],
    );
  }

  /// Updates notebook metadata inside the same journal/projection transaction.
  Future<void> _touchNotebook(String uid) async {
    final row = await (database.select(
      database.notebookRows,
    )..where((item) => item.uid.equals(uid))).getSingleOrNull();
    if (row == null) {
      throw StateError('The committed notebook disappeared from SQLite.');
    }
    final now = DateTime.now().toUtc();
    // Drift stores this DateTime column in whole seconds. Do not invent
    // future timestamps just to distinguish rapid edits: actorSeq and
    // the operation journal are the durable, monotonic change record.
    if (!now.isAfter(row.updatedAt)) {
      return;
    }
    await (database.update(database.notebookRows)
          ..where((item) => item.uid.equals(uid)))
        .write(NotebookRowsCompanion(updatedAt: Value(now)));
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
    final target = operation.kind.target;
    final documentTarget = target == OperationTarget.document;
    final pageTarget = target == OperationTarget.page;
    final kinds = documentTarget
        ? "('document.create', 'document.set')"
        : pageTarget
        ? "('page.create', 'page.set')"
        : "('stroke.create', 'object.create', 'object.set', "
              "'object.transform', 'object.reorder', 'object.move')";
    final rows = await database
        .customSelect(
          'SELECT envelope_json FROM operations '
          'WHERE document_id = ? AND '
          '${documentTarget ? 'object_id IS NULL' : 'object_id = ?'} '
          'AND kind IN $kinds',
          variables: [
            Variable<String>(operation.documentId),
            if (!documentTarget) Variable<String>(operation.objectId!),
          ],
        )
        .get();
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
        OperationKind.documentCreate ||
        OperationKind.pageCreate ||
        OperationKind.objectCreate ||
        OperationKind.strokeCreate => previous.payload['value'],
        OperationKind.documentSet ||
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

  static int _compareRank(OperationEnvelope left, OperationEnvelope right) {
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
    if (value.keys.any((key) => key != 'title' && key != 'isBookmarked') ||
        value['title'] is! String ||
        value['isBookmarked'] is! bool) {
      throw const FormatException('Invalid page creation properties.');
    }
    final existing = await _row('SELECT uid FROM page_rows WHERE uid = ?', [
      Variable<String>(id),
    ]);
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
    var changes = Map<String, dynamic>.from(op.payload['properties'] as Map);
    if (changes.isEmpty ||
        changes.keys.any((key) => key != 'title' && key != 'isBookmarked') ||
        (changes.containsKey('title') && changes['title'] is! String) ||
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

    final imageRows = await database
        .customSelect(
          'SELECT uid FROM image_block_rows WHERE page_uid = ?',
          variables: [Variable<String>(pageId)],
        )
        .get();
    final textRows = await database
        .customSelect(
          'SELECT uid, delta_json FROM text_block_rows WHERE page_uid = ?',
          variables: [Variable<String>(pageId)],
        )
        .get();
    final imageIds = {for (final row in imageRows) row.read<String>('uid')};
    final textIds = {for (final row in textRows) row.read<String>('uid')};
    final prefix = 'page:[${jsonEncode(pageId)},';
    final attached = await database
        .customSelect(
          'SELECT object_id, asset_id FROM asset_references '
          'WHERE document_id = ? AND substr(object_id, 1, ?) = ?',
          variables: [
            Variable<String>(op.documentId),
            Variable<int>(prefix.length),
            Variable<String>(prefix),
          ],
        )
        .get();
    final assetsByOwner = <String, Set<String>>{};
    for (final row in attached) {
      final encodedOwner = row.read<String>('object_id');
      final parts = jsonDecode(encodedOwner.substring('page:'.length));
      if (parts is! List ||
          parts.length != 2 ||
          parts[0] != pageId ||
          parts[1] is! String) {
        throw const FormatException('Invalid scoped asset reference.');
      }
      final owner = parts[1] as String;
      if (!imageIds.contains(owner) && !textIds.contains(owner)) {
        throw UnsupportedError('Page has an unowned media reference.');
      }
      assetsByOwner
          .putIfAbsent(owner, () => <String>{})
          .add(row.read<String>('asset_id'));
    }
    for (final id in imageIds) {
      if (!assetsByOwner.containsKey(id)) {
        throw UnsupportedError(
          'Deleting an image/PDF page requires verified asset references.',
        );
      }
    }
    for (final row in textRows) {
      final deltaJson = row.readNullable<String>('delta_json');
      if (deltaJson == null) {
        continue;
      }
      final delta = jsonDecode(deltaJson);
      if (delta is! List) {
        throw const FormatException('Invalid stored Quill Delta.');
      }
      for (final item in delta) {
        if (item is! Map) {
          throw const FormatException('Invalid stored Quill entry.');
        }
        final insert = item['insert'];
        if (insert is Map) {
          final id = OperationEnvelope.embedAssetId(insert);
          if (!(assetsByOwner[row.read<String>('uid')]?.contains(id) ??
              false)) {
            throw UnsupportedError('Unverified embed on deleted page.');
          }
        }
      }
    }

    await database.customStatement(
      'DELETE FROM asset_references WHERE document_id = ? '
      'AND substr(object_id, 1, ?) = ?',
      [op.documentId, prefix.length, prefix],
    );
    for (final table in [
      'ink_stroke_rows',
      'text_block_rows',
      'image_block_rows',
    ]) {
      await database.customStatement('DELETE FROM $table WHERE page_uid = ?', [
        pageId,
      ]);
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
    final fields = Map<String, dynamic>.from(op.payload['value'] as Map);
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

  /// Resolves concurrent moves by the same durable v2 rank as field writes.
  ///
  /// A move from another actor may have already relocated the object. A newer
  /// concurrent move then applies from that actual page, while an older one is
  /// an accepted no-op. A causally wrong source still fails closed.
  Future<void> _moveObject(OperationEnvelope op) async {
    final sourceId = op.pageId!;
    final destinationId = op.payload['toPageId'] as String;
    final index = _index(op.payload['sortIndex']);
    final priorMoves = await database
        .customSelect(
          'SELECT envelope_json FROM operations '
          "WHERE document_id = ? AND object_id = ? AND kind = 'object.move'",
          variables: [
            Variable<String>(op.documentId),
            Variable<String>(op.objectId!),
          ],
        )
        .get();
    if (priorMoves.length > 50000) {
      throw StateError('Move history requires a durable checkpoint.');
    }
    OperationEnvelope? previousWinner;
    for (final row in priorMoves) {
      final value = jsonDecode(row.read<String>('envelope_json'));
      if (value is! Map) {
        throw const FormatException('Malformed durable move envelope.');
      }
      final previous = OperationEnvelope.fromJson(
        Map<String, dynamic>.from(value),
      );
      if (previousWinner == null ||
          _compareRank(previous, previousWinner) > 0) {
        previousWinner = previous;
      }
    }
    if (previousWinner != null && _compareRank(previousWinner, op) >= 0) {
      // Its actorSeq and checkpoint must still be recorded by OperationStore.
      return;
    }

    await _pageExists(op, sourceId);
    await _pageExists(op, destinationId);
    if (await _store.isTombstoned(op.documentId, 'page', destinationId)) {
      throw StateError('Destination page has been tombstoned.');
    }
    final ink = await _row(
      'SELECT page_uid FROM ink_stroke_rows WHERE uid = ?',
      [Variable<String>(op.objectId!)],
    );
    final image = await _row(
      'SELECT page_uid FROM image_block_rows WHERE uid = ?',
      [Variable<String>(op.objectId!)],
    );
    final text = await _row(
      'SELECT page_uid, delta_json FROM text_block_rows WHERE uid = ?',
      [Variable<String>(op.objectId!)],
    );
    final matches =
        (ink == null ? 0 : 1) +
        (image == null ? 0 : 1) +
        (text == null ? 0 : 1);
    if (matches != 1) {
      throw StateError('Missing or ambiguous move target identity.');
    }
    final actualSourceId = (ink ?? image ?? text)!['page_uid'] as String;
    if (actualSourceId != sourceId) {
      if (previousWinner == null ||
          previousWinner.actorId == op.actorId ||
          op.dependencies.contains(previousWinner.operationId)) {
        throw UnsupportedError('Causal move source is inconsistent.');
      }
    }
    await _pageExists(op, actualSourceId);
    final sourceAssetKey = 'page:${jsonEncode([actualSourceId, op.objectId])}';
    final destinationAssetKey =
        'page:${jsonEncode([destinationId, op.objectId])}';
    final linked = await database
        .customSelect(
          'SELECT asset_id FROM asset_references '
          'WHERE document_id = ? AND object_id = ?',
          variables: [
            Variable<String>(op.documentId),
            Variable<String>(sourceAssetKey),
          ],
        )
        .get();
    if (ink != null && linked.isNotEmpty) {
      throw UnsupportedError('Ink cannot move with attached media assets.');
    }
    if (text != null) {
      final assetIds = {for (final row in linked) row.read<String>('asset_id')};
      for (final assetId in assetIds) {
        await verifiedTextAssetBytes(
          documentId: op.documentId,
          pageId: actualSourceId,
          objectId: op.objectId!,
          assetId: assetId,
        );
      }
      final delta = jsonDecode(text['delta_json'] as String? ?? '[]');
      if (delta is! List) {
        throw const FormatException('Invalid stored Quill Delta.');
      }
      for (final entry in delta) {
        if (entry is! Map) {
          throw const FormatException('Invalid stored Quill entry.');
        }
        final embed = entry['insert'];
        if (embed is Map &&
            !assetIds.contains(OperationEnvelope.embedAssetId(embed))) {
          throw StateError('Moved Quill embed is missing its scoped asset.');
        }
      }
    }
    if (image != null && linked.isEmpty) {
      throw UnsupportedError(
        'Image moves require durable scoped asset references.',
      );
    }
    if ((image != null || text != null) && actualSourceId != destinationId) {
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
    final table = ink != null
        ? 'ink_stroke_rows'
        : image != null
        ? 'image_block_rows'
        : 'text_block_rows';
    await database.customStatement(
      'UPDATE $table SET page_uid = ?, sort_index = ? '
      'WHERE uid = ? AND page_uid = ?',
      [destinationId, index, op.objectId, actualSourceId],
    );
  }

  Future<Map<String, dynamic>> _storedStroke(OperationEnvelope op) async {
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
    var changes = Map<String, dynamic>.from(op.payload['properties'] as Map);
    final allowed = switch (op.kind) {
      OperationKind.objectTransform => {'points'},
      OperationKind.objectReorder => {'sortIndex'},
      _ => {'colorValue', 'width', 'toolIndex'},
    };
    if (changes.isEmpty || changes.keys.any((key) => !allowed.contains(key))) {
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
    final matches =
        (ink == null ? 0 : 1) +
        (text == null ? 0 : 1) +
        (image == null ? 0 : 1);
    if (matches != 1) {
      throw StateError('Missing or ambiguous editor object identity.');
    }

    final scopedId = 'page:${jsonEncode([op.pageId, op.objectId])}';
    final attached = await database
        .customSelect(
          'SELECT asset_id FROM asset_references '
          'WHERE document_id = ? AND object_id = ?',
          variables: [
            Variable<String>(op.documentId),
            Variable<String>(scopedId),
          ],
        )
        .get();
    final assetIds = {for (final row in attached) row.read<String>('asset_id')};
    if (image != null && assetIds.isEmpty) {
      throw UnsupportedError('Image deletion requires a verified asset.');
    }
    if (ink != null && assetIds.isNotEmpty) {
      throw UnsupportedError('Ink cannot own a verified media asset.');
    }
    if (text != null && text['delta_json'] != null) {
      final delta = jsonDecode(text['delta_json'] as String);
      if (delta is! List) {
        throw const FormatException('Invalid stored Quill Delta.');
      }
      for (final item in delta) {
        if (item is! Map) {
          throw const FormatException('Invalid stored Quill entry.');
        }
        final insert = item['insert'];
        if (insert is Map &&
            !assetIds.contains(OperationEnvelope.embedAssetId(insert))) {
          throw UnsupportedError('Quill embed is missing its asset.');
        }
      }
    }
    await database.customStatement(
      ink != null
          ? 'DELETE FROM ink_stroke_rows WHERE uid = ? AND page_uid = ?'
          : image != null
          ? 'DELETE FROM image_block_rows WHERE uid = ? AND page_uid = ?'
          : 'DELETE FROM text_block_rows WHERE uid = ? AND page_uid = ?',
      [op.objectId, op.pageId],
    );
    if (assetIds.isNotEmpty) {
      await database.customStatement(
        'DELETE FROM asset_references '
        'WHERE document_id = ? AND object_id = ?',
        [op.documentId, scopedId],
      );
    }
  }

  /// Detaches an asset only after no persisted object still references it.
  ///
  /// Bytes/files are never deleted here. Physical garbage collection waits
  /// for acknowledged checkpoints and remains a separate migration step.
  Future<void> _detachUnusedAsset(OperationEnvelope operation) async {
    final pageId = operation.pageId!;
    final objectId = operation.objectId!;
    await _pageExists(operation, pageId);
    final assetId = operation.payload['assetId'] as String;
    final scopedId = 'page:${jsonEncode([pageId, objectId])}';
    final reference = await _row(
      'SELECT checksum_sha256 FROM asset_references '
      'WHERE document_id = ? AND object_id = ? AND asset_id = ?',
      [
        Variable<String>(operation.documentId),
        Variable<String>(scopedId),
        Variable<String>(assetId),
      ],
    );
    final image = await _imageRow(operation);
    if (reference == null) {
      if (image != null &&
          await verifiedImageAssetId(
                documentId: operation.documentId,
                pageId: pageId,
                objectId: objectId,
              ) !=
              assetId) {
        // Another concurrent replacement already detached this old ID.
        return;
      }
      throw StateError('An asset must be attached before detachment.');
    }

    final text = await _textRow(operation);
    if (text != null && image != null) {
      throw StateError('Ambiguous image and Quill asset ownership.');
    }
    if (image != null) {
      final currentId = await verifiedImageAssetId(
        documentId: operation.documentId,
        pageId: pageId,
        objectId: objectId,
      );
      if (currentId == assetId) {
        throw UnsupportedError('Cannot detach an active image asset.');
      }
    }
    if (text != null && text['delta_json'] != null) {
      final delta = jsonDecode(text['delta_json'] as String);
      if (delta is! List) {
        throw const FormatException('Malformed persisted Quill Delta.');
      }
      for (final item in delta) {
        if (item is! Map) {
          throw const FormatException('Malformed persisted Quill entry.');
        }
        final insert = item['insert'];
        if (insert is Map &&
            OperationEnvelope.embedAssetId(insert) == assetId) {
          throw StateError('A live Quill embed still references this asset.');
        }
      }
    }
    await database.customStatement(
      'DELETE FROM asset_references '
      'WHERE document_id = ? AND object_id = ? AND asset_id = ?',
      [operation.documentId, scopedId, assetId],
    );
  }

  /// Finds the durable receipt for an asset already attached to this object.
  Future<Map<String, dynamic>?> _attachedReceipt({
    required String documentId,
    required String pageId,
    required String objectId,
    required String assetId,
  }) async {
    final rows = await database
        .customSelect(
          'SELECT envelope_json FROM operations WHERE document_id = ? '
          'AND page_id = ? AND object_id = ? AND kind = ?',
          variables: [
            Variable<String>(documentId),
            Variable<String>(pageId),
            Variable<String>(objectId),
            const Variable<String>('asset.attach'),
          ],
        )
        .get();
    if (rows.length > 50000) {
      throw StateError('Asset history requires a checkpoint.');
    }
    Map<String, dynamic>? receipt;
    for (final row in rows) {
      final decoded = jsonDecode(row.read<String>('envelope_json'));
      if (decoded is! Map) {
        throw const FormatException('Malformed asset operation.');
      }
      final candidate = OperationEnvelope.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (candidate.payload['assetId'] == assetId) {
        receipt = candidate.payload;
      }
    }
    return receipt;
  }

  /// Downloads verified bytes before a remote attach or image switch.
  ///
  /// An already committed attach may precede an object.set by a restart.
  /// The receipt is recovered from the journal and can be downloaded again.
  /// Never call this method while a SQLite transaction is open.
  Future<void> prepareRemoteMedia(
    OperationEnvelope operation,
    OperationAssetGateway gateway,
  ) async {
    final buffer = verifiedAssetBuffer;
    if (buffer == null) {
      throw UnsupportedError('Verified asset staging is unavailable.');
    }
    Map<String, dynamic>? receipt;
    if (operation.kind == OperationKind.assetAttach) {
      receipt = operation.payload;
    } else if (operation.kind == OperationKind.objectSet) {
      final properties = operation.payload['properties'];
      if (properties is Map && properties['assetId'] is String) {
        receipt = await _attachedReceipt(
          documentId: operation.documentId,
          pageId: operation.pageId!,
          objectId: operation.objectId!,
          assetId: properties['assetId'] as String,
        );
      }
    }
    if (receipt == null) {
      if (operation.kind == OperationKind.assetAttach) {
        throw StateError('Asset attach has no verified receipt.');
      }
      if (operation.kind == OperationKind.objectSet &&
          (operation.payload['properties'] as Map).containsKey('assetId')) {
        throw StateError('Image replacement has no durable asset receipt.');
      }
      return;
    }
    try {
      buffer.requireBytes(receipt);
      return;
    } on StateError {
      await gateway.downloadAndStage(receipt: receipt, buffer: buffer);
    }
  }

  /// Returns the one verified asset currently rendered by an image.
  ///
  /// Content hashes distinguish the live reference from staged replacements.
  /// Legacy path-only images and ambiguous aliases cannot be replaced.
  Future<String> verifiedImageAssetId({
    required String documentId,
    required String pageId,
    required String objectId,
  }) async {
    final image = await _row(
      'SELECT bytes, path FROM image_block_rows '
      'WHERE uid = ? AND page_uid = ?',
      [Variable<String>(objectId), Variable<String>(pageId)],
    );
    final bytes = image?['bytes'];
    if (image == null ||
        image['path'] != '' ||
        bytes is! Uint8List ||
        bytes.isEmpty) {
      throw UnsupportedError(
        'Only durable verified image bytes can change their asset ID.',
      );
    }
    final digest = crypto.sha256.convert(bytes).toString();
    final scopedId = 'page:${jsonEncode([pageId, objectId])}';
    final references = await database
        .customSelect(
          'SELECT asset_id, checksum_sha256 FROM asset_references '
          'WHERE document_id = ? AND object_id = ?',
          variables: [Variable<String>(documentId), Variable<String>(scopedId)],
        )
        .get();
    final matching = [
      for (final row in references)
        if (row.read<String>('checksum_sha256') == digest)
          row.read<String>('asset_id'),
    ];
    if (matching.length != 1) {
      throw StateError('Image has no unique verified current asset.');
    }
    return matching.single;
  }

  Future<Map<String, dynamic>?> _imageRow(OperationEnvelope op) => _row(
    'SELECT dx, dy, width, height, rotation, crop_left, crop_top, '
    'crop_right, crop_bottom, sort_index FROM image_block_rows '
    'WHERE uid = ? AND page_uid = ?',
    [Variable<String>(op.objectId!), Variable<String>(op.pageId!)],
  );

  /// Applies a checked image asset swap or independent geometry fields.
  ///
  /// An attach operation must already own the verified new bytes. The
  /// currently visible image changes only when the winning object.set
  /// commits; a losing concurrent replacement leaves its bytes unchanged.
  Future<void> _updateImage(OperationEnvelope op) async {
    await _pageExists(op, op.pageId!);
    final row = await _imageRow(op);
    if (row == null) {
      throw StateError('Missing image object.');
    }
    var changes = Map<String, dynamic>.from(op.payload['properties'] as Map);
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
        changes.keys.any(
          (key) => key != 'assetId' && !allowed.containsKey(key),
        )) {
      throw const FormatException('Unsupported image properties.');
    }
    for (final entry in changes.entries) {
      if (entry.key == 'assetId') {
        if (entry.value is! String ||
            (entry.value as String).isEmpty ||
            (entry.value as String).length > 128) {
          throw const FormatException('Invalid replacement asset ID.');
        }
      } else if (entry.key == 'sortIndex') {
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
    final replacementId = changes.remove('assetId') as String?;
    final updates = [for (final key in changes.keys) '${allowed[key]} = ?'];
    final values = <Object?>[...changes.values];
    if (replacementId != null) {
      final currentId = await verifiedImageAssetId(
        documentId: op.documentId,
        pageId: op.pageId!,
        objectId: op.objectId!,
      );
      if (currentId == replacementId) {
        throw StateError('Replacement must use a new asset identity.');
      }
      final scopedId = 'page:${jsonEncode([op.pageId, op.objectId])}';
      final reference = await _row(
        'SELECT checksum_sha256, byte_length FROM asset_references '
        'WHERE document_id = ? AND object_id = ? AND asset_id = ?',
        [
          Variable<String>(op.documentId),
          Variable<String>(scopedId),
          Variable<String>(replacementId),
        ],
      );
      if (reference == null) {
        throw StateError('Replacement asset has not been attached.');
      }
      final receipt = await _attachedReceipt(
        documentId: op.documentId,
        pageId: op.pageId!,
        objectId: op.objectId!,
        assetId: replacementId,
      );
      if (receipt == null ||
          receipt['sha256'] != reference['checksum_sha256'] ||
          receipt['sizeBytes'] != reference['byte_length']) {
        throw StateError('Replacement has no verified attachment receipt.');
      }
      final cache = verifiedAssetBuffer;
      if (cache == null) {
        throw UnsupportedError('Verified asset staging is unavailable.');
      }
      final bytes = cache.requireBytes(receipt);
      updates.addAll([
        'path = ?',
        'ocr_text = ?',
        'bytes = ?',
        'image_ext = ?',
        'image_mime = ?',
      ]);
      values.addAll([
        '',
        '',
        bytes,
        _imageExtension(receipt['mediaType'] as String),
        receipt['mediaType'],
      ]);
    }
    if (updates.isEmpty) {
      return;
    }
    await database.customStatement(
      'UPDATE image_block_rows SET ${updates.join(', ')} '
      'WHERE uid = ? AND page_uid = ?',
      [...values, op.objectId, op.pageId],
    );
  }

  Future<Map<String, dynamic>?> _textRow(OperationEnvelope op) => _row(
    'SELECT text, delta_json, font_size, color_value, width, rotation, '
    'dx, dy, sort_index FROM text_block_rows '
    'WHERE uid = ? AND page_uid = ?',
    [Variable<String>(op.objectId!), Variable<String>(op.pageId!)],
  );

  /// Creates image metadata only; the visible row is written at attach time.
  ///
  /// This avoids exposing an empty or damaged placeholder to a remote editor
  /// when an object.create event arrives before verified asset.attach.
  Future<void> _createObject(OperationEnvelope op) async {
    final value = Map<String, dynamic>.from(op.payload['value'] as Map);
    if (value['objectType'] == 'image') {
      await _validateImageCreate(op, value);
      return;
    }
    await _createText(op);
  }

  Future<void> _validateImageCreate(
    OperationEnvelope operation,
    Map<String, dynamic> value,
  ) async {
    await _pageExists(operation, operation.pageId!);
    await _objectIdUnused(operation.objectId!);
    const expected = <String>{
      'objectType',
      'assetId',
      'dx',
      'dy',
      'width',
      'height',
      'rotation',
      'cropLeft',
      'cropTop',
      'cropRight',
      'cropBottom',
      'sortIndex',
    };
    final assetId = value['assetId'];
    if (value.length != expected.length ||
        value.keys.any((key) => !expected.contains(key)) ||
        assetId is! String ||
        assetId.isEmpty ||
        assetId.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(assetId)) {
      throw const FormatException('Invalid v2 image creation payload.');
    }
    _validateImageGeometry(value);
  }

  static void _validateImageGeometry(Map<String, dynamic> value) {
    _index(value['sortIndex']);
    for (final name in [
      'dx',
      'dy',
      'width',
      'height',
      'rotation',
      'cropLeft',
      'cropTop',
      'cropRight',
      'cropBottom',
    ]) {
      final number = value[name];
      if (number is! num ||
          !number.toDouble().isFinite ||
          (const {'width', 'height'}.contains(name) && number <= 0) ||
          (name.startsWith('crop') && (number < 0 || number > 1))) {
        throw const FormatException('Invalid v2 image geometry.');
      }
    }
  }

  /// Converts checksum-verified local or downloaded bytes into a durable image.
  /// No external network call is made while the journal transaction is open.
  Future<void> _attachVerifiedAsset(OperationEnvelope operation) async {
    final pageId = operation.pageId!;
    final objectId = operation.objectId!;
    await _pageExists(operation, pageId);
    final cache = verifiedAssetBuffer;
    if (cache == null) {
      throw UnsupportedError('Verified asset staging has not been installed.');
    }
    final receipt = operation.payload;
    final bytes = cache.requireBytes(receipt);
    final assetId = receipt['assetId'] as String;
    final sha = receipt['sha256'] as String;
    final mime = receipt['mediaType'] as String;
    await _storeAssetBytes(
      operation: operation,
      bytes: bytes,
      sha: sha,
      mime: mime,
    );
    final existingImage = await _imageRow(operation);
    final existingText = await _textRow(operation);
    if (existingText != null && existingImage != null) {
      throw StateError('Ambiguous media object identity.');
    }
    if (existingText != null) {
      await _storeTextAsset(operation: operation, bytes: bytes, sha: sha);
      return;
    }
    final original = await _row(
      'SELECT envelope_json FROM operations '
      'WHERE document_id = ? AND page_id = ? AND object_id = ? '
      "AND kind = 'object.create' ORDER BY rowid LIMIT 1",
      [
        Variable<String>(operation.documentId),
        Variable<String>(pageId),
        Variable<String>(objectId),
      ],
    );
    if (original == null) {
      throw StateError('Image must have an authenticated create operation.');
    }
    final envelope = OperationEnvelope.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(original['envelope_json'] as String) as Map,
      ),
    );
    final creation = Map<String, dynamic>.from(
      envelope.payload['value'] as Map,
    );
    if (creation['objectType'] != 'image') {
      throw StateError('Asset identity belongs to a non-image object.');
    }
    if (existingImage == null) {
      if (creation['assetId'] != assetId) {
        throw StateError('Image creation receipt does not match its asset.');
      }
    } else {
      final currentId = await verifiedImageAssetId(
        documentId: operation.documentId,
        pageId: pageId,
        objectId: objectId,
      );
      if (currentId == assetId) {
        throw StateError('Cannot reattach the current image asset.');
      }
      final currentRef = await _row(
        'SELECT checksum_sha256 FROM asset_references '
        'WHERE document_id = ? AND object_id = ? AND asset_id = ?',
        [
          Variable<String>(operation.documentId),
          Variable<String>('page:${jsonEncode([pageId, objectId])}'),
          Variable<String>(currentId),
        ],
      );
      if (currentRef == null || currentRef['checksum_sha256'] == sha) {
        throw StateError('Replacement must have distinct verified bytes.');
      }
    }

    final scopedObjectId = 'page:${jsonEncode([pageId, objectId])}';
    final alreadyAttached = await _row(
      'SELECT checksum_sha256, byte_length, storage_path '
      'FROM asset_references '
      'WHERE document_id = ? AND object_id = ? AND asset_id = ?',
      [
        Variable<String>(operation.documentId),
        Variable<String>(scopedObjectId),
        Variable<String>(assetId),
      ],
    );
    if (alreadyAttached != null &&
        (alreadyAttached['checksum_sha256'] != sha ||
            alreadyAttached['byte_length'] != bytes.length)) {
      throw StateError('Asset ID reused with incompatible bytes.');
    }
    if (alreadyAttached == null) {
      await database.customStatement(
        'INSERT INTO asset_references '
        '(document_id, object_id, asset_id, storage_path, '
        'checksum_sha256, byte_length) VALUES (?, ?, ?, ?, ?, ?)',
        [
          operation.documentId,
          scopedObjectId,
          assetId,
          'sqlite-blob:$sha',
          sha,
          bytes.length,
        ],
      );
    }

    if (existingImage == null) {
      await _validateImageCreate(operation, creation);
      final ext = _imageExtension(mime);
      await database.customStatement(
        'INSERT INTO image_block_rows '
        '(uid, page_uid, path, ocr_text, bytes, image_ext, image_mime, '
        'width, height, rotation, dx, dy, crop_left, crop_top, '
        'crop_right, crop_bottom, sort_index) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          objectId,
          pageId,
          '',
          '',
          bytes,
          ext,
          mime,
          (creation['width'] as num).toDouble(),
          (creation['height'] as num).toDouble(),
          (creation['rotation'] as num).toDouble(),
          (creation['dx'] as num).toDouble(),
          (creation['dy'] as num).toDouble(),
          (creation['cropLeft'] as num).toDouble(),
          (creation['cropTop'] as num).toDouble(),
          (creation['cropRight'] as num).toDouble(),
          (creation['cropBottom'] as num).toDouble(),
          creation['sortIndex'],
        ],
      );
    }
  }

  Future<void> _storeAssetBytes({
    required OperationEnvelope operation,
    required Uint8List bytes,
    required String sha,
    required String mime,
  }) async {
    final existingId = await _row(
      'SELECT checksum_sha256, byte_length FROM asset_references '
      'WHERE asset_id = ? LIMIT 1',
      [Variable<String>(operation.payload['assetId'] as String)],
    );
    if (existingId != null &&
        (existingId['checksum_sha256'] != sha ||
            existingId['byte_length'] != bytes.length)) {
      throw StateError('Asset identity cannot refer to different bytes.');
    }
    final prior = await _row(
      'SELECT media_type, byte_length, bytes '
      'FROM operation_asset_bytes WHERE checksum_sha256 = ?',
      [Variable<String>(sha)],
    );
    if (prior != null) {
      final stored = prior['bytes'];
      if (prior['media_type'] != mime ||
          prior['byte_length'] != bytes.length ||
          stored is! Uint8List ||
          !const ListEquality<int>().equals(stored, bytes)) {
        throw StateError('Existing asset bytes do not match receipt.');
      }
    } else {
      await database.customStatement(
        'INSERT INTO operation_asset_bytes '
        '(checksum_sha256, media_type, byte_length, bytes) '
        'VALUES (?, ?, ?, ?)',
        [sha, mime, bytes.length, bytes],
      );
    }
  }

  /// Persists Quill embed bytes transactionally with their scoped reference.
  ///
  /// This is separate from the image-row BLOB so restarting without network
  /// access does not strand embedded images or PDF references.
  Future<void> _storeTextAsset({
    required OperationEnvelope operation,
    required Uint8List bytes,
    required String sha,
  }) async {
    final owner = 'page:${jsonEncode([operation.pageId, operation.objectId])}';
    final reference = await _row(
      'SELECT checksum_sha256, byte_length, storage_path '
      'FROM asset_references '
      'WHERE document_id = ? AND object_id = ? AND asset_id = ?',
      [
        Variable<String>(operation.documentId),
        Variable<String>(owner),
        Variable<String>(operation.payload['assetId'] as String),
      ],
    );
    if (reference != null) {
      if (reference['checksum_sha256'] != sha ||
          reference['byte_length'] != bytes.length ||
          reference['storage_path'] != 'sqlite-asset:$sha') {
        throw StateError('Existing scoped embed reference is inconsistent.');
      }
      return;
    }
    await database.customStatement(
      'INSERT INTO asset_references '
      '(document_id, object_id, asset_id, storage_path, '
      'checksum_sha256, byte_length) VALUES (?, ?, ?, ?, ?, ?)',
      [
        operation.documentId,
        owner,
        operation.payload['assetId'],
        'sqlite-asset:$sha',
        sha,
        bytes.length,
      ],
    );
  }

  Future<String> _assetChecksum(
    String documentId,
    String owner,
    String assetId,
  ) async {
    final ref = await _row(
      'SELECT checksum_sha256 FROM asset_references '
      'WHERE document_id = ? AND object_id = ? AND asset_id = ?',
      [
        Variable<String>(documentId),
        Variable<String>(owner),
        Variable<String>(assetId),
      ],
    );
    if (ref == null) {
      throw StateError('Missing scoped embed reference.');
    }
    return ref['checksum_sha256'] as String;
  }

  /// Reads upload bytes independently of visible objects or scoped references.
  /// Deleted offline objects may still have unacknowledged attach operations.
  Future<Uint8List> verifiedUploadBytes(Map<String, dynamic> receipt) async {
    final sha = receipt['sha256'] as String;
    final row = await _row(
      'SELECT bytes, byte_length, media_type FROM operation_asset_bytes '
      'WHERE checksum_sha256 = ?',
      [Variable<String>(sha)],
    );
    final bytes = row?['bytes'];
    if (bytes is! Uint8List ||
        row?['byte_length'] != receipt['sizeBytes'] ||
        row?['media_type'] != receipt['mediaType'] ||
        bytes.length != receipt['sizeBytes'] ||
        crypto.sha256.convert(bytes).toString() != sha) {
      throw const FormatException('Missing or corrupt durable upload bytes.');
    }
    return Uint8List.fromList(bytes);
  }

  /// Returns checksum-verified persisted embed bytes after an app restart.
  Future<Uint8List> verifiedTextAssetBytes({
    required String documentId,
    required String pageId,
    required String objectId,
    required String assetId,
  }) async {
    final owner = 'page:${jsonEncode([pageId, objectId])}';
    final row = await _row(
      'SELECT r.checksum_sha256, r.byte_length, r.storage_path, '
      'b.bytes, b.media_type FROM asset_references r '
      'JOIN operation_asset_bytes b '
      'ON b.checksum_sha256 = r.checksum_sha256 '
      'WHERE r.document_id = ? AND r.object_id = ? AND r.asset_id = ?',
      [
        Variable<String>(documentId),
        Variable<String>(owner),
        Variable<String>(assetId),
      ],
    );
    if (row == null) {
      throw StateError('Missing durable Quill embed reference.');
    }
    final bytes = row['bytes'];
    final sha = row['checksum_sha256'];
    if (bytes is! Uint8List ||
        sha is! String ||
        row['byte_length'] != bytes.length ||
        row['storage_path'] != 'sqlite-asset:$sha' ||
        crypto.sha256.convert(bytes).toString() != sha) {
      throw const FormatException('Corrupt persistent Quill embed.');
    }
    return Uint8List.fromList(bytes);
  }

  static String _imageExtension(String mime) => switch (mime) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    'application/pdf' => 'pdf',
    _ => throw const FormatException('Unsupported materialized MIME type.'),
  };

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
    var changes = Map<String, dynamic>.from(op.payload['properties'] as Map);
    if (changes.isEmpty ||
        changes.keys.any(
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
    final checkedAssets = <String>{};
    for (final id in OperationTextSequence.visibleIds(updated)) {
      final atom = updated[id] as Map;
      final embed = atom['embed'];
      if (embed is! Map) {
        continue;
      }
      final assetId = OperationEnvelope.embedAssetId(embed);
      if (!checkedAssets.add(assetId)) {
        continue;
      }
      final owner = 'page:${jsonEncode([op.pageId, op.objectId])}';
      final linked = await _row(
        'SELECT b.media_type FROM asset_references r '
        'JOIN operation_asset_bytes b '
        'ON b.checksum_sha256 = r.checksum_sha256 '
        'WHERE r.document_id = ? AND r.object_id = ? AND r.asset_id = ? '
        'AND r.storage_path = ? AND r.byte_length = b.byte_length',
        [
          Variable<String>(op.documentId),
          Variable<String>(owner),
          Variable<String>(assetId),
          Variable<String>(
            'sqlite-asset:' +
                (await _assetChecksum(op.documentId, owner, assetId)),
          ),
        ],
      );
      final mime = linked?['media_type'];
      final valid = embed.containsKey('pdf')
          ? mime == 'application/pdf'
          : const {'image/png', 'image/jpeg', 'image/webp'}.contains(mime);
      if (!valid) {
        throw StateError('Quill embed has no verified matching local asset.');
      }
    }
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
      if (value is! num ||
          !value.toDouble().isFinite ||
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
      {'dx': point[0], 'dy': point[1], 'pressure': point[2]},
  ]);
}
