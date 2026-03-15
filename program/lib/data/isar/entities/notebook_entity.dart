import 'package:isar/isar.dart';

part 'notebook_entity.g.dart';

@collection
class NotebookEntity {
  Id id = Isar.autoIncrement;
  late String uid;
  late String title;
  late DateTime createdAt;
  late DateTime updatedAt;
  late List<NotePageEntity> pages;
}

@embedded
class NotePageEntity {
  late String uid;
  late int index;
  late String title;
  late bool isBookmarked;
  late List<StrokeEntity> strokes;
  late List<ShapeEntity> shapes;
  late List<TextBlockEntity> textBlocks;
  late List<ImageBlockEntity> imageBlocks;
}

@embedded
class StrokeEntity {
  late String uid;
  late int tool;
  late int colorValue;
  late double width;
  late List<StrokePointEntity> points;
}

@embedded
class ShapeEntity {
  late String uid;
  late int type;
  late int colorValue;
  late double width;
  late double startDx;
  late double startDy;
  late double endDx;
  late double endDy;
}

@embedded
class TextBlockEntity {
  late String uid;
  late String text;
  late double fontSize;
  late int colorValue;
  late double width;
  late double dx;
  late double dy;
}

@embedded
class ImageBlockEntity {
  late String uid;
  late String path;
  late String ocrText;
  late double width;
  late double height;
  late double dx;
  late double dy;
}

@embedded
class StrokePointEntity {
  late double dx;
  late double dy;
  late double pressure;
}
