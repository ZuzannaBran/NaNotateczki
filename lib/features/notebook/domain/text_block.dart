import 'dart:ui';

class TextBlock {
  TextBlock({
    required this.id,
    required this.text,
    required this.position,
    required this.fontSize,
    required this.color,
    required this.width,
  });

  final String id;
  final String text;
  final Offset position;
  final double fontSize;
  final Color color;
  final double width;

  TextBlock copyWith({
    String? id,
    String? text,
    Offset? position,
    double? fontSize,
    Color? color,
    double? width,
  }) {
    return TextBlock(
      id: id ?? this.id,
      text: text ?? this.text,
      position: position ?? this.position,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      width: width ?? this.width,
    );
  }
}
