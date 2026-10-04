import 'image_block.dart';
import 'ink_stroke.dart';
import 'text_block.dart';

class NotePage {
  NotePage({
    required this.id,
    required this.title,
    required this.textBlocks,
    required this.imageBlocks,
    required this.inkStrokes,
    required this.isBookmarked,
  });

  final String id;
  final String title;
  final List<TextBlock> textBlocks;
  final List<ImageBlock> imageBlocks;
  final List<InkStroke> inkStrokes;
  final bool isBookmarked;

  NotePage copyWith({
    String? id,
    String? title,
    List<TextBlock>? textBlocks,
    List<ImageBlock>? imageBlocks,
    List<InkStroke>? inkStrokes,
    bool? isBookmarked,
  }) {
    return NotePage(
      id: id ?? this.id,
      title: title ?? this.title,
      textBlocks: textBlocks ?? this.textBlocks,
      imageBlocks: imageBlocks ?? this.imageBlocks,
      inkStrokes: inkStrokes ?? this.inkStrokes,
      isBookmarked: isBookmarked ?? this.isBookmarked,
    );
  }
}
