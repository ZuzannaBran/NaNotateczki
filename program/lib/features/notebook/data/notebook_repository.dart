import 'dart:ui';

import 'package:isar/isar.dart';
import 'package:uuid/uuid.dart';

import '../../../data/isar/entities/notebook_entity.dart';
import '../domain/drawing_tool.dart';
import '../domain/image_block.dart';
import '../domain/notebook.dart';
import '../domain/note_page.dart';
import '../domain/shape.dart';
import '../domain/stroke.dart';
import '../domain/stroke_point.dart';
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
          strokes: <Stroke>[],
          shapes: <Shape>[],
          textBlocks: <TextBlock>[],
          imageBlocks: <ImageBlock>[],
          redoStack: <Stroke>[],
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
      strokes: entity.strokes.map(_strokeFromEntity).toList(),
      shapes: entity.shapes.map(_shapeFromEntity).toList(),
      textBlocks: entity.textBlocks.map(_textFromEntity).toList(),
      imageBlocks: entity.imageBlocks.map(_imageFromEntity).toList(),
      redoStack: <Stroke>[],
      isBookmarked: entity.isBookmarked,
    );
  }

  Stroke _strokeFromEntity(StrokeEntity entity) {
    return Stroke(
      id: entity.uid.isEmpty ? _uuid.v4() : entity.uid,
      points: entity.points
          .map(
            (point) => StrokePoint(
              dx: point.dx,
              dy: point.dy,
              pressure: point.pressure,
            ),
          )
          .toList(),
      color: Color(entity.colorValue),
      width: entity.width,
      tool: DrawingTool.values[entity.tool],
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
      ..strokes = page.strokes.map(_strokeToEntity).toList()
      ..shapes = page.shapes.map(_shapeToEntity).toList()
      ..textBlocks = page.textBlocks.map(_textToEntity).toList()
      ..imageBlocks = page.imageBlocks.map(_imageToEntity).toList();
  }

  StrokeEntity _strokeToEntity(Stroke stroke) {
    return StrokeEntity()
      ..uid = stroke.id
      ..tool = stroke.tool.index
      ..colorValue = stroke.color.toARGB32()
      ..width = stroke.width
      ..points = stroke.points
          .map(
            (point) => StrokePointEntity()
              ..dx = point.dx
              ..dy = point.dy
              ..pressure = point.pressure,
          )
          .toList();
  }

  Shape _shapeFromEntity(ShapeEntity entity) {
    return Shape(
      id: entity.uid,
      type: ShapeType.values[entity.type],
      color: Color(entity.colorValue),
      width: entity.width,
      start: Offset(entity.startDx, entity.startDy),
      end: Offset(entity.endDx, entity.endDy),
    );
  }

  ShapeEntity _shapeToEntity(Shape shape) {
    return ShapeEntity()
      ..uid = shape.id
      ..type = shape.type.index
      ..colorValue = shape.color.toARGB32()
      ..width = shape.width
      ..startDx = shape.start.dx
      ..startDy = shape.start.dy
      ..endDx = shape.end.dx
      ..endDy = shape.end.dy;
  }

  TextBlock _textFromEntity(TextBlockEntity entity) {
    return TextBlock(
      id: entity.uid,
      text: entity.text,
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
      'strokes': page.strokes.map(_strokeToJson).toList(),
      'shapes': page.shapes.map(_shapeToJson).toList(),
      'textBlocks': page.textBlocks.map(_textToJson).toList(),
      'imageBlocks': page.imageBlocks.map(_imageToJson).toList(),
    };
  }

  NotePage _pageFromJson(Map<String, dynamic> json) {
    return NotePage(
      id: json['id'] as String,
      title: json['title'] as String,
      strokes: (json['strokes'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_strokeFromJson)
          .toList(),
      shapes: (json['shapes'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_shapeFromJson)
          .toList(),
      textBlocks: (json['textBlocks'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_textFromJson)
          .toList(),
      imageBlocks: (json['imageBlocks'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(_imageFromJson)
          .toList(),
      redoStack: <Stroke>[],
      isBookmarked: json['isBookmarked'] as bool? ?? false,
    );
  }

  Map<String, dynamic> _strokeToJson(Stroke stroke) {
    return {
      'id': stroke.id,
      'tool': stroke.tool.index,
      'color': stroke.color.toARGB32(),
      'width': stroke.width,
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

  Stroke _strokeFromJson(Map<String, dynamic> json) {
    return Stroke(
      id: json['id'] as String,
      tool: DrawingTool.values[json['tool'] as int],
      color: Color(json['color'] as int),
      width: (json['width'] as num).toDouble(),
      points: (json['points'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(
            (point) => StrokePoint(
              dx: (point['dx'] as num).toDouble(),
              dy: (point['dy'] as num).toDouble(),
              pressure: (point['pressure'] as num).toDouble(),
            ),
          )
          .toList(),
    );
  }

  Map<String, dynamic> _shapeToJson(Shape shape) {
    return {
      'id': shape.id,
      'type': shape.type.index,
      'color': shape.color.toARGB32(),
      'width': shape.width,
      'startDx': shape.start.dx,
      'startDy': shape.start.dy,
      'endDx': shape.end.dx,
      'endDy': shape.end.dy,
    };
  }

  Shape _shapeFromJson(Map<String, dynamic> json) {
    return Shape(
      id: json['id'] as String,
      type: ShapeType.values[json['type'] as int],
      color: Color(json['color'] as int),
      width: (json['width'] as num).toDouble(),
      start: Offset(
        (json['startDx'] as num).toDouble(),
        (json['startDy'] as num).toDouble(),
      ),
      end: Offset(
        (json['endDx'] as num).toDouble(),
        (json['endDy'] as num).toDouble(),
      ),
    );
  }

  Map<String, dynamic> _textToJson(TextBlock block) {
    return {
      'id': block.id,
      'text': block.text,
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
}
