import 'package:isar/isar.dart';

part 'notebook_entity.g.dart';

@collection
class NotebookEntity {
  Id id = Isar.autoIncrement;
  late String uid;
  late String title;
  late int kindIndex;
  late String folder;
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
  int? indexTabColorValue;
  double? indexTabPosition;
  late List<IndexTabEntity> indexTabs;
  late List<TextBlockEntity> textBlocks;
  late List<ImageBlockEntity> imageBlocks;
  late List<InkStrokeEntity> inkStrokes;
}

@embedded
class IndexTabEntity {
  late String uid;
  late int colorValue;
  late double position;
}

@embedded
class TextBlockEntity {
  late String uid;
  late String text;
  String? deltaJson;
  late double fontSize;
  late int colorValue;
  late double width;
  late double rotation;
  late double dx;
  late double dy;
}

@embedded
class ImageBlockEntity {
  late String uid;
  late String path;
  late String ocrText;
  List<int>? bytes;
  String? imageExt;
  String? imageMime;
  late double width;
  late double height;
  late double rotation;
  late double dx;
  late double dy;
  late double cropLeft;
  late double cropTop;
  late double cropRight;
  late double cropBottom;
}

@embedded
class InkStrokeEntity {
  late String uid;
  late int colorValue;
  late double width;
  late int toolIndex;
  late List<InkPointEntity> points;
}

@embedded
class InkPointEntity {
  late double dx;
  late double dy;
  late double pressure;
}
