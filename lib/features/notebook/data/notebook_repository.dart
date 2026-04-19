import 'dart:ui';

import 'package:isar/isar.dart';
import 'package:uuid/uuid.dart';

import '../../../data/isar/entities/notebook_entity.dart';
import '../domain/drawing_tool.dart';
import '../domain/image_block.dart';
import '../domain/ink_stroke.dart';
import '../domain/notebook.dart';
import '../domain/note_page.dart';
import '../domain/text_block.dart';

class NotebookRepository {
  NotebookRepository(this.isar);

  final Isar isar;
  final Uuid _uuid = const Uuid();

  Future<List<Notebook>> fetchNotebooks() async {
    final entities = await isar.notebookEntitys
        .where()
        .sortByUpdatedAtDesc()
        .findAll();
    return entities.map(_fromEntity).toList();
  }

  Future<Notebook> createNotebook({String? title}) async {
    final now = DateTime.now();
    final notebook = Notebook(
      uid: _uuid.v4(),
      title: title ?? 'New Notebook',
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
        ),
      ],
    );

    await saveNotebook(notebook);
    return notebook;
  }

  Future<Notebook?> getNotebook(String uid) async {
    final entity = await isar.notebookEntitys
        .filter()
        .uidEqualTo(uid)
        .findFirst();
    if (entity == null) {
      return null;
    }
    return _fromEntity(entity);
  }

  Future<void> saveNotebook(Notebook notebook) async {
    await isar.writeTxn(() async {
      final existing = await isar.notebookEntitys
          .filter()
          .uidEqualTo(notebook.uid)
          .findFirst();
      final entity = _toEntity(notebook, existing?.id);
      await isar.notebookEntitys.put(entity);
    });
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
    );
  }

  NotebookEntity _toEntity(Notebook notebook, int? existingId) {
    final entity = NotebookEntity()
      ..id = existingId ?? Isar.autoIncrement
      ..uid = notebook.uid
      ..title = notebook.title
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
      ..textBlocks = page.textBlocks.map(_textToEntity).toList()
        ..imageBlocks = page.imageBlocks.map(_imageToEntity).toList()
        ..inkStrokes = page.inkStrokes.map(_strokeToEntity).toList();
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
    );
  }

  ImageBlockEntity _imageToEntity(ImageBlock block) {
    return ImageBlockEntity()
      ..uid = block.id
      ..path = block.path
      ..ocrText = block.ocrText
      ..width = block.width
      ..height = block.height
      ..dx = block.position.dx
      ..dy = block.position.dy;
  }

  InkStroke _strokeFromEntity(InkStrokeEntity entity) {
    final tool = _toolFromIndex(entity.toolIndex);
    return InkStroke(
      id: entity.uid,
      points: entity.points
          .map((item) => InkPoint(
                dx: item.dx,
                dy: item.dy,
                pressure: item.pressure,
              ))
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
          .map((point) => InkPointEntity()
            ..dx = point.dx
            ..dy = point.dy
            ..pressure = point.pressure)
          .toList();
  }

  Map<String, dynamic> _notebookToJson(Notebook notebook) {
    return {
      'uid': notebook.uid,
      'title': notebook.title,
      'createdAt': notebook.createdAt.toIso8601String(),
      'updatedAt': notebook.updatedAt.toIso8601String(),
      'pages': notebook.pages.map(_pageToJson).toList(),
    };
  }

  Notebook _notebookFromJson(Map<String, dynamic> json) {
    return Notebook(
      uid: json['uid'] as String,
      title: json['title'] as String,
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
    );
  }

  Map<String, dynamic> _imageToJson(ImageBlock block) {
    return {
      'id': block.id,
      'path': block.path,
      'ocrText': block.ocrText,
      'width': block.width,
      'height': block.height,
      'dx': block.position.dx,
      'dy': block.position.dy,
    };
  }

  ImageBlock _imageFromJson(Map<String, dynamic> json) {
    return ImageBlock(
      id: json['id'] as String,
      path: json['path'] as String? ?? '',
      ocrText: json['ocrText'] as String? ?? '',
      position: Offset(
        (json['dx'] as num).toDouble(),
        (json['dy'] as num).toDouble(),
      ),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
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
    if (index == 14) {
      return DrawingTool.blockArrow;
    }
    if (index == 1) {
      return DrawingTool.pen;
    }
    if (index >= 2) {
      index -= 1;
    }
    if (index == 6) {
      return DrawingTool.arrow;
    }
    if (index > 6) {
      index -= 1;
    }
    return DrawingTool.values.elementAt(
      index.clamp(0, DrawingTool.values.length - 1),
    );
  }

  int _toolToIndex(DrawingTool tool) {
    final index = tool.index;
    if (index >= 1) {
      return index + 1;
    }
    return index;
  }
}
