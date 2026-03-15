import 'image_block.dart';
import 'shape.dart';
import 'stroke.dart';
import 'text_block.dart';

class NotePage {
  NotePage({
    required this.id,
    required this.title,
    required this.strokes,
    required this.shapes,
    required this.textBlocks,
    required this.imageBlocks,
    required this.redoStack,
    required this.isBookmarked,
  });

  final String id;
  final String title;
  final List<Stroke> strokes;
  final List<Shape> shapes;
  final List<TextBlock> textBlocks;
  final List<ImageBlock> imageBlocks;
  final List<Stroke> redoStack;
  final bool isBookmarked;

  NotePage copyWith({
    String? id,
    String? title,
    List<Stroke>? strokes,
    List<Shape>? shapes,
    List<TextBlock>? textBlocks,
    List<ImageBlock>? imageBlocks,
    List<Stroke>? redoStack,
    bool? isBookmarked,
  }) {
    return NotePage(
      id: id ?? this.id,
      title: title ?? this.title,
      strokes: strokes ?? this.strokes,
      shapes: shapes ?? this.shapes,
      textBlocks: textBlocks ?? this.textBlocks,
      imageBlocks: imageBlocks ?? this.imageBlocks,
      redoStack: redoStack ?? this.redoStack,
      isBookmarked: isBookmarked ?? this.isBookmarked,
    );
  }
}
