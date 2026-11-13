import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/editor_sqlite_projector.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/verified_editor_asset_buffer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cases =
      jsonDecode(
            File('test/fixtures/v2_projection_corpus.json').readAsStringSync(),
          )
          as List;
  for (final rawCase in cases) {
    final scenario = rawCase as Map;
    test('Python/SQLite projection: ${scenario['name']}', () async {
      final directory = await Directory.systemTemp.createTemp('v2-parity-');
      final path = File('${directory.path}/notes.sqlite');
      var database = NotesDatabase(NativeDatabase(path));
      addTearDown(() async {
        await database.close();
        await directory.delete(recursive: true);
      });
      final buffer = VerifiedEditorAssetBuffer();
      for (final asset in scenario['assets'] as List? ?? const []) {
        buffer.stage(
          receipt: Map<String, dynamic>.from(asset['receipt'] as Map),
          bytes: Uint8List.fromList(base64Decode(asset['base64'] as String)),
        );
      }
      final store = OperationStore(database);
      final projector = EditorSqliteProjector(
        database,
        verifiedAssetBuffer: buffer,
      );
      var sequence = 0;
      for (final raw in scenario['operations'] as List) {
        final operation = OperationEnvelope.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        await store.applyRemote(
          operation,
          serverSequence: ++sequence,
          apply: () => projector.apply(operation),
        );
        expect(
          (await store.operation(operation.operationId))!.toJson(),
          operation.toJson(),
          reason: 'Projection must preserve the original envelope.',
        );
      }
      expect(await _snapshot(database), scenario['expected']);
      await database.close();
      buffer.clear();
      database = NotesDatabase(NativeDatabase(path));
      expect(await _snapshot(database), scenario['expected']);
      expect(await OperationStore(database).pending(), isEmpty);
    });
  }
}

Future<Map<String, dynamic>> _snapshot(NotesDatabase database) async {
  Future<List<Map<String, dynamic>>> rows(String table) async => [
    for (final row in await database.customSelect('SELECT * FROM $table').get())
      row.data,
  ];
  final notebooks = await rows('notebook_rows');
  Map<String, dynamic>? document;
  if (notebooks.isNotEmpty) {
    final notebook = notebooks.single;
    final pages = <String, dynamic>{};
    for (final page in await rows('page_rows')) {
      pages[page['uid'] as String] = {
        'title': page['title'],
        'isBookmarked': page['is_bookmarked'] == 1,
        'objects': <String, dynamic>{},
        'order': <String>[],
      };
    }
    for (final ink in await rows('ink_stroke_rows')) {
      final objects = pages[ink['page_uid']]['objects'] as Map;
      objects[ink['uid']] = {
        'objectType': 'stroke',
        'colorValue': ink['color_value'],
        'width': ink['width'],
        'toolIndex': ink['tool_index'],
        'sortIndex': ink['sort_index'],
        'points': [
          for (final point in jsonDecode(ink['points_json'] as String) as List)
            [point['dx'], point['dy'], point['pressure']],
        ],
      };
    }
    final references = await rows('asset_references');
    final bytes = await rows('operation_asset_bytes');
    for (final text in await rows('text_block_rows')) {
      final objects = pages[text['page_uid']]['objects'] as Map;
      final owner = 'page:${jsonEncode([text['page_uid'], text['uid']])}';
      objects[text['uid']] = {
        'objectType': 'text',
        'fontSize': text['font_size'],
        'colorValue': text['color_value'],
        'width': text['width'],
        'rotation': text['rotation'],
        'dx': text['dx'],
        'dy': text['dy'],
        'sortIndex': text['sort_index'],
        'text': text['text'],
        'delta': text['delta_json'] == null
            ? null
            : jsonDecode(text['delta_json'] as String),
        'assets': {
          for (final ref in references.where((r) => r['object_id'] == owner))
            ref['asset_id'] as String: {
              'sha256': ref['checksum_sha256'],
              'sizeBytes': ref['byte_length'],
              'mediaType': bytes.singleWhere(
                (b) => b['checksum_sha256'] == ref['checksum_sha256'],
              )['media_type'],
            },
        },
      };
    }
    for (final page in pages.values) {
      final objects = page['objects'] as Map;
      page['order'] = objects.keys.cast<String>().toList()
        ..sort((a, b) {
          final order = (objects[a]['sortIndex'] as int).compareTo(
            objects[b]['sortIndex'] as int,
          );
          return order == 0 ? a.compareTo(b) : order;
        });
    }
    document = {
      'title': notebook['title'],
      'folder': notebook['folder'],
      'kindIndex': notebook['kind_index'],
      'pages': pages,
    };
  }
  final deleted = [
    for (final row in await rows('object_tombstones'))
      [
        row['target_kind'],
        row['page_id'],
        row['target_kind'] == 'document' ? '' : row['object_id'],
      ],
  ]..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
  return {'document': document, 'tombstones': deleted};
}
