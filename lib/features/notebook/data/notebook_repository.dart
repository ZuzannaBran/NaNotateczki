import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';
import 'package:uuid/uuid.dart';

import '../../../data/isar/entities/notebook_entity.dart';
import '../domain/drawing_tool.dart';
import '../domain/image_block.dart';
import '../domain/ink_stroke.dart';
import '../domain/notebook.dart';
import '../domain/notebook_kind.dart';
import '../domain/note_page.dart';
import '../domain/text_block.dart';

class NotebookRepository {
  NotebookRepository(this.isar, {this.onChanged});

  final Isar isar;
  final void Function()? onChanged;
  final Uuid _uuid = const Uuid();
  bool _lastFetchSkippedCorruptRows = false;

  bool get lastFetchSkippedCorruptRows => _lastFetchSkippedCorruptRows;

  Future<List<Notebook>> fetchNotebooks() async {
    try {
      final entities = await isar.notebookEntitys
          .where()
          .sortByUpdatedAtDesc()
          .findAll();
      _lastFetchSkippedCorruptRows = false;
      return entities.map(_fromEntity).toList();
    } catch (e, st) {
      debugPrint('fetchNotebooks failed, falling back to defensive: $e\n$st');
      return _fetchNotebooksDefensively();
    }
  }

  Future<List<Notebook>> _fetchNotebooksDefensively() async {
    final List<Notebook> results = <Notebook>[];
    final corruptIds = <int>[];
    try {
      final ids = await isar.notebookEntitys.where().idProperty().findAll();
      for (final id in ids) {
        try {
          final entity = await isar.notebookEntitys.get(id);
          if (entity != null) {
            results.add(_fromEntity(entity));
          }
        } catch (e) {
          corruptIds.add(id);
          debugPrint('Skipped corrupt notebook id=$id: $e');
        }
      }
    } catch (e) {
      debugPrint('Defensive fetch failed at idProperty stage: $e');
    }
    _lastFetchSkippedCorruptRows = corruptIds.isNotEmpty;
    if (corruptIds.isNotEmpty) {
      debugPrint('Defensive fetch: skipped ${corruptIds.length} corrupt rows');
      await _deleteCorruptRows(corruptIds);
    }
    results.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return results;
  }

  Future<void> _deleteCorruptRows(List<int> ids) async {
    try {
      await isar.writeTxn(() => isar.notebookEntitys.deleteAll(ids));
      debugPrint('Deleted ${ids.length} corrupt notebook rows');
    } catch (e) {
      debugPrint('Failed to delete corrupt notebook rows $ids: $e');
    }
  }

  Future<Notebook> createNotebook({String? title, String? folder}) async {
    final now = DateTime.now();
    final notebook = Notebook(
      uid: _uuid.v4(),
      title: title ?? 'New Notebook',
      kind: NotebookKind.notebook,
      folder: folder ?? 'Notes',
      createdAt: now,
      updatedAt: now,
      pages: [
        NotePage(
          id: _uuid.v4(),
          title: 'Page 1',
          textBlocks: <TextBlock>[],
          imageBlocks: <ImageBlock>[],
          inkStrokes: <InkStroke>[],
          isBookmarked: false,
          indexTabs: <IndexTab>[],
        ),
      ],
    );

    await saveNotebook(notebook);
    return notebook;
  }

  Future<Notebook> createBoard({String? title, String? folder}) async {
    final now = DateTime.now();
    final board = Notebook(
      uid: _uuid.v4(),
      title: title ?? 'New Board',
      kind: NotebookKind.board,
      folder: folder ?? 'Notes',
      createdAt: now,
      updatedAt: now,
      pages: [
        NotePage(
          id: _uuid.v4(),
          title: 'Canvas',
          textBlocks: <TextBlock>[],
          imageBlocks: <ImageBlock>[],
          inkStrokes: <InkStroke>[],
          isBookmarked: false,
          indexTabs: <IndexTab>[],
        ),
      ],
    );

    await saveNotebook(board);
    return board;
  }

  Future<Notebook?> getNotebook(String uid) async {
    try {
      final entity = await isar.notebookEntitys
          .filter()
          .uidEqualTo(uid)
          .findFirst();
      if (entity == null) {
        return null;
      }
      return _fromEntity(entity);
    } catch (e) {
      debugPrint('getNotebook failed for uid=$uid: $e');
      return null;
    }
  }

  Future<void> saveNotebook(Notebook notebook) async {
    final diagnosticsStopwatch = kDebugMode ? (Stopwatch()..start()) : null;
    if (kDebugMode) {
      final textBlocks = notebook.pages.fold<int>(
        0,
        (sum, page) => sum + page.textBlocks.length,
      );
      final imageBlocks = notebook.pages.fold<int>(
        0,
        (sum, page) => sum + page.imageBlocks.length,
      );
      final strokes = notebook.pages.fold<int>(
        0,
        (sum, page) => sum + page.inkStrokes.length,
      );
      debugPrint(
        'TextInputDiag repo save begin uid=${notebook.uid} '
        'pages=${notebook.pages.length} textBlocks=$textBlocks '
        'imageBlocks=$imageBlocks strokes=$strokes',
      );
    }
    final migratedPages = <NotePage>[];
    bool migrated = false;
    final migrationStopwatch = kDebugMode ? (Stopwatch()..start()) : null;
    for (final page in notebook.pages) {
      final migratedBlocks = <ImageBlock>[];
      bool pageMigrated = false;
      for (final block in page.imageBlocks) {
        if (block.bytes == null && block.path.isNotEmpty) {
          final file = File(block.path);
          if (file.existsSync()) {
            try {
              final bytes = await file.readAsBytes();
              final ext = block.path.split('.').last.toLowerCase();
              String mime = 'image/jpeg';
              if (ext == 'png') {
                mime = 'image/png';
              } else if (ext == 'gif') {
                mime = 'image/gif';
              } else if (ext == 'webp') {
                mime = 'image/webp';
              }

              migratedBlocks.add(
                block.copyWith(bytes: bytes, imageExt: ext, imageMime: mime),
              );
              pageMigrated = true;
              migrated = true;
              continue;
            } catch (e) {
              debugPrint(
                'NotebookRepository.saveNotebook: image migration '
                'failed for ${block.id}: $e',
              );
            }
          }
        }
        migratedBlocks.add(block);
      }
      migratedPages.add(
        pageMigrated ? page.copyWith(imageBlocks: migratedBlocks) : page,
      );
    }
    migrationStopwatch?.stop();
    if (kDebugMode) {
      debugPrint(
        'TextInputDiag repo migration done uid=${notebook.uid} '
        'migrated=$migrated elapsedMs='
        '${migrationStopwatch?.elapsedMilliseconds}',
      );
    }

    final notebookToSave = migrated
        ? notebook.copyWith(pages: migratedPages)
        : notebook;

    final transactionStopwatch = kDebugMode ? (Stopwatch()..start()) : null;
    await isar.writeTxn(() async {
      final existing = await isar.notebookEntitys
          .filter()
          .uidEqualTo(notebookToSave.uid)
          .findFirst();
      final entity = _toEntity(notebookToSave, existing?.id);
      await isar.notebookEntitys.put(entity);
    });
    transactionStopwatch?.stop();
    if (kDebugMode) {
      debugPrint(
        'TextInputDiag repo txn done uid=${notebook.uid} '
        'elapsedMs=${transactionStopwatch?.elapsedMilliseconds}',
      );
    }
    onChanged?.call();
    diagnosticsStopwatch?.stop();
    if (kDebugMode) {
      debugPrint(
        'TextInputDiag repo save done uid=${notebook.uid} '
        'elapsedMs=${diagnosticsStopwatch?.elapsedMilliseconds}',
      );
    }
  }

  Future<void> deleteNotebook(String uid) async {
    await isar.writeTxn(() async {
      final existing = await isar.notebookEntitys
          .filter()
          .uidEqualTo(uid)
          .findFirst();
      if (existing == null) {
        return;
      }
      await isar.notebookEntitys.delete(existing.id);
    });
    onChanged?.call();
  }

  List<Map<String, dynamic>> encodeNotebooks(List<Notebook> items) {
    return items.map(_notebookToJson).toList();
  }

  List<Notebook> decodeNotebooks(List<dynamic> items) {
    return items
        .whereType<Map<String, dynamic>>()
        .map(_notebookFromJson)
        .toList();
  }

  Notebook _fromEntity(NotebookEntity entity) {
    return Notebook(
      uid: entity.uid,
      title: entity.title,
      kind: NotebookKindValue.fromIndex(entity.kindIndex),
      folder: entity.folder,
      createdAt: entity.createdAt,
      updatedAt: entity.updatedAt,
      pages: entity.pages.map(_pageFromEntity).toList(),
    );
  }

  NotePage _pageFromEntity(NotePageEntity entity) {
    return NotePage(
      id: entity.uid,
      title: entity.title,
      textBlocks: entity.textBlocks.map(_textFromEntity).toList(),
      imageBlocks: entity.imageBlocks.map(_imageFromEntity).toList(),
      inkStrokes: entity.inkStrokes.map(_strokeFromEntity).toList(),
      isBookmarked: entity.isBookmarked,
      indexTabs: _indexTabsFromEntity(entity),
    );
  }

  NotebookEntity _toEntity(Notebook notebook, int? existingId) {
    final entity = NotebookEntity()
      ..id = existingId ?? Isar.autoIncrement
      ..uid = notebook.uid
      ..title = notebook.title
      ..kindIndex = notebook.kind.indexValue
      ..folder = notebook.folder
      ..createdAt = notebook.createdAt
      ..updatedAt = notebook.updatedAt
      ..pages = notebook.pages
          .asMap()
          .entries
          .map((entry) => _pageToEntity(entry.value, entry.key))
          .toList();

    return entity;
  }

  NotePageEntity _pageToEntity(NotePage page, int index) {
    return NotePageEntity()
      ..uid = page.id
      ..index = index
      ..title = page.title
      ..isBookmarked = page.isBookmarked
      ..indexTabColorValue = page.indexTabs.firstOrNull?.color.toARGB32()
      ..indexTabPosition = page.indexTabs.firstOrNull?.position
      ..indexTabs = page.indexTabs.map(_indexTabToEntity).toList()
      ..textBlocks = page.textBlocks.map(_textToEntity).toList()
      ..imageBlocks = page.imageBlocks.map(_imageToEntity).toList()
      ..inkStrokes = page.inkStrokes.map(_strokeToEntity).toList();
  }

  List<IndexTab> _indexTabsFromEntity(NotePageEntity entity) {
    final tabs = entity.indexTabs.map(_indexTabFromEntity).toList();
    if (tabs.isNotEmpty || entity.indexTabColorValue == null) {
      return tabs;
    }
    return [
      IndexTab(
        id: const Uuid().v4(),
        color: Color(entity.indexTabColorValue!),
        position: entity.indexTabPosition ?? 0.0,
      ),
    ];
  }

  IndexTab _indexTabFromEntity(IndexTabEntity entity) {
    return IndexTab(
      id: entity.uid,
      color: Color(entity.colorValue),
      position: entity.position,
    );
  }

  IndexTabEntity _indexTabToEntity(IndexTab tab) {
    return IndexTabEntity()
      ..uid = tab.id
      ..colorValue = tab.color.toARGB32()
      ..position = tab.position;
  }

  TextBlock _textFromEntity(TextBlockEntity entity) {
    return TextBlock(
      id: entity.uid,
      text: entity.text,
      deltaJson: entity.deltaJson,
      position: Offset(entity.dx, entity.dy),
      fontSize: entity.fontSize,
      color: Color(entity.colorValue),
      width: entity.width,
      rotation: entity.rotation,
    );
  }

  TextBlockEntity _textToEntity(TextBlock block) {
    return TextBlockEntity()
      ..uid = block.id
      ..text = block.text
      ..deltaJson = block.deltaJson
      ..fontSize = block.fontSize
      ..colorValue = block.color.toARGB32()
      ..width = block.width
      ..rotation = block.rotation
      ..dx = block.position.dx
      ..dy = block.position.dy;
  }

  ImageBlock _imageFromEntity(ImageBlockEntity entity) {
    return ImageBlock(
      id: entity.uid,
      path: entity.path,
      ocrText: entity.ocrText,
      position: Offset(entity.dx, entity.dy),
      width: entity.width,
      height: entity.height,
      bytes: _bytesFromEntity(entity.bytes),
      imageExt: entity.imageExt,
      imageMime: entity.imageMime,
      rotation: entity.rotation,
      cropLeft: entity.cropLeft,
      cropTop: entity.cropTop,
      cropRight: entity.cropRight,
      cropBottom: entity.cropBottom,
    );
  }

  ImageBlockEntity _imageToEntity(ImageBlock block) {
    return ImageBlockEntity()
      ..uid = block.id
      ..path = block.path
      ..ocrText = block.ocrText
      ..bytes = block.bytes?.toList()
      ..imageExt = block.imageExt
      ..imageMime = block.imageMime
      ..width = block.width
      ..height = block.height
      ..rotation = block.rotation
      ..dx = block.position.dx
      ..dy = block.position.dy
      ..cropLeft = block.cropLeft
      ..cropTop = block.cropTop
      ..cropRight = block.cropRight
      ..cropBottom = block.cropBottom;
  }

  InkStroke _strokeFromEntity(InkStrokeEntity entity) {
    final tool = _toolFromIndex(entity.toolIndex);
    return InkStroke(
      id: entity.uid,
      points: entity.points
          .map(
            (item) =>
                InkPoint(dx: item.dx, dy: item.dy, pressure: item.pressure),
          )
          .toList(),
      color: Color(entity.colorValue),
      width: entity.width,
      tool: tool,
    );
  }

  InkStrokeEntity _strokeToEntity(InkStroke stroke) {
    return InkStrokeEntity()
      ..uid = stroke.id
      ..colorValue = stroke.color.toARGB32()
      ..width = stroke.width
      ..toolIndex = _toolToIndex(stroke.tool)
      ..points = stroke.points
          .map(
            (point) => InkPointEntity()
              ..dx = point.dx
              ..dy = point.dy
              ..pressure = point.pressure,
          )
          .toList();
  }

  Map<String, dynamic> _notebookToJson(Notebook notebook) {
    return {
      'uid': notebook.uid,
      'title': notebook.title,
      'kind': notebook.kind.indexValue,
      'folder': notebook.folder,
      'createdAt': notebook.createdAt.toIso8601String(),
      'updatedAt': notebook.updatedAt.toIso8601String(),
      'pages': notebook.pages.map(_pageToJson).toList(),
    };
  }

  Notebook _notebookFromJson(Map<String, dynamic> json) {
    return Notebook(
      uid: json['uid'] as String,
      title: json['title'] as String,
      kind: NotebookKindValue.fromIndex((json['kind'] as num?)?.toInt() ?? 0),
      folder: (json['folder'] as String?) ?? 'Notes',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      pages: (json['pages'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_pageFromJson)
          .toList(),
    );
  }

  Map<String, dynamic> _pageToJson(NotePage page) {
    return {
      'id': page.id,
      'title': page.title,
      'isBookmarked': page.isBookmarked,
      'indexTabColor': page.indexTabs.firstOrNull?.color.toARGB32(),
      'indexTabPosition': page.indexTabs.firstOrNull?.position,
      'indexTabs': page.indexTabs.map(_indexTabToJson).toList(),
      'textBlocks': page.textBlocks.map(_textToJson).toList(),
      'imageBlocks': page.imageBlocks.map(_imageToJson).toList(),
      'inkStrokes': page.inkStrokes.map(_strokeToJson).toList(),
    };
  }

  NotePage _pageFromJson(Map<String, dynamic> json) {
    return NotePage(
      id: json['id'] as String,
      title: json['title'] as String,
      textBlocks: (json['textBlocks'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_textFromJson)
          .toList(),
      imageBlocks: (json['imageBlocks'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_imageFromJson)
          .toList(),
      inkStrokes: (json['inkStrokes'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(_strokeFromJson)
          .toList(),
      isBookmarked: json['isBookmarked'] as bool? ?? false,
      indexTabs: _indexTabsFromJson(json),
    );
  }

  Map<String, dynamic> _indexTabToJson(IndexTab tab) {
    return {
      'id': tab.id,
      'color': tab.color.toARGB32(),
      'position': tab.position,
    };
  }

  List<IndexTab> _indexTabsFromJson(Map<String, dynamic> json) {
    final tabs = (json['indexTabs'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(_indexTabFromJson)
        .toList();
    if (tabs.isNotEmpty || json['indexTabColor'] == null) {
      return tabs;
    }
    return [
      IndexTab(
        id: const Uuid().v4(),
        color: Color(json['indexTabColor'] as int),
        position: (json['indexTabPosition'] as num?)?.toDouble() ?? 0.0,
      ),
    ];
  }

  IndexTab _indexTabFromJson(Map<String, dynamic> json) {
    return IndexTab(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      color: Color(json['color'] as int),
      position: (json['position'] as num).toDouble(),
    );
  }

  Map<String, dynamic> _textToJson(TextBlock block) {
    return {
      'id': block.id,
      'text': block.text,
      'deltaJson': block.deltaJson,
      'fontSize': block.fontSize,
      'color': block.color.toARGB32(),
      'width': block.width,
      'rotation': block.rotation,
      'dx': block.position.dx,
      'dy': block.position.dy,
    };
  }

  TextBlock _textFromJson(Map<String, dynamic> json) {
    return TextBlock(
      id: json['id'] as String,
      text: json['text'] as String,
      deltaJson: json['deltaJson'] as String?,
      position: Offset(
        (json['dx'] as num).toDouble(),
        (json['dy'] as num).toDouble(),
      ),
      fontSize: (json['fontSize'] as num).toDouble(),
      color: Color(json['color'] as int),
      width: (json['width'] as num).toDouble(),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> _imageToJson(ImageBlock block) {
    final bytesBase64 = _bytesToBase64(block.bytes);
    return {
      'id': block.id,
      'path': block.path,
      'ocrText': block.ocrText,
      'bytes': bytesBase64,
      'imageExt': block.imageExt,
      'imageMime': block.imageMime,
      'width': block.width,
      'height': block.height,
      'rotation': block.rotation,
      'cropLeft': block.cropLeft,
      'cropTop': block.cropTop,
      'cropRight': block.cropRight,
      'cropBottom': block.cropBottom,
      'dx': block.position.dx,
      'dy': block.position.dy,
    };
  }

  ImageBlock _imageFromJson(Map<String, dynamic> json) {
    return ImageBlock(
      id: json['id'] as String,
      path: json['path'] as String? ?? '',
      ocrText: json['ocrText'] as String? ?? '',
      bytes: _bytesFromBase64(json['bytes']),
      imageExt: json['imageExt'] as String?,
      imageMime: json['imageMime'] as String?,
      position: Offset(
        (json['dx'] as num).toDouble(),
        (json['dy'] as num).toDouble(),
      ),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      cropLeft: (json['cropLeft'] as num?)?.toDouble() ?? 0.0,
      cropTop: (json['cropTop'] as num?)?.toDouble() ?? 0.0,
      cropRight: (json['cropRight'] as num?)?.toDouble() ?? 1.0,
      cropBottom: (json['cropBottom'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> _strokeToJson(InkStroke stroke) {
    return {
      'id': stroke.id,
      'color': stroke.color.toARGB32(),
      'width': stroke.width,
      'tool': _toolToIndex(stroke.tool),
      'points': stroke.points
          .map(
            (point) => {
              'dx': point.dx,
              'dy': point.dy,
              'pressure': point.pressure,
            },
          )
          .toList(),
    };
  }

  InkStroke _strokeFromJson(Map<String, dynamic> json) {
    final toolIndex = (json['tool'] as num?)?.toInt() ?? 0;
    final tool = _toolFromIndex(toolIndex);
    return InkStroke(
      id: json['id'] as String,
      color: Color(json['color'] as int),
      width: (json['width'] as num).toDouble(),
      tool: tool,
      points: (json['points'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(
            (point) => InkPoint(
              dx: (point['dx'] as num).toDouble(),
              dy: (point['dy'] as num).toDouble(),
              pressure: (point['pressure'] as num?)?.toDouble() ?? 0.5,
            ),
          )
          .toList(),
    );
  }

  DrawingTool _toolFromIndex(int index) {
    final values = DrawingTool.values;
    if (index < 0 || index >= values.length) {
      return DrawingTool.pen;
    }
    return values[index];
  }

  int _toolToIndex(DrawingTool tool) => tool.index;

  Uint8List? _bytesFromEntity(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return Uint8List.fromList(bytes);
  }

  String? _bytesToBase64(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return base64Encode(bytes);
  }

  Uint8List? _bytesFromBase64(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    try {
      return base64Decode(value);
    } catch (_) {
      return null;
    }
  }
}
