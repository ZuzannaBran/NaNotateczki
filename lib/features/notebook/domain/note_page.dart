import 'dart:ui';

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
    required this.indexTabs,
  });

  final String id;
  final String title;
  final List<TextBlock> textBlocks;
  final List<ImageBlock> imageBlocks;
  final List<InkStroke> inkStrokes;
  final bool isBookmarked;
  final List<IndexTab> indexTabs;

  NotePage copyWith({
    String? id,
    String? title,
    List<TextBlock>? textBlocks,
    List<ImageBlock>? imageBlocks,
    List<InkStroke>? inkStrokes,
    bool? isBookmarked,
    List<IndexTab>? indexTabs,
  }) {
    return NotePage(
      id: id ?? this.id,
      title: title ?? this.title,
      textBlocks: textBlocks ?? this.textBlocks,
      imageBlocks: imageBlocks ?? this.imageBlocks,
      inkStrokes: inkStrokes ?? this.inkStrokes,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      indexTabs: indexTabs ?? this.indexTabs,
    );
  }

  NotePage withoutIndexTab(String tabId) {
    return copyWith(
      indexTabs: indexTabs.where((tab) => tab.id != tabId).toList(),
    );
  }
}

class IndexTab {
  const IndexTab({
    required this.id,
    required this.color,
    required this.position,
  });

  final String id;
  final Color color;
  final double position;

  IndexTab copyWith({Color? color, double? position}) {
    return IndexTab(
      id: id,
      color: color ?? this.color,
      position: position ?? this.position,
    );
  }
}
