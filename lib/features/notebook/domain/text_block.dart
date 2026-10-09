import 'dart:ui';

class TextBlock {
  TextBlock({
    required this.id,
    required this.text,
    this.deltaJson,
    required this.position,
    required this.fontSize,
    required this.color,
    required this.width,
    this.rotation = 0.0,
  });

  final String id;
  final String text;
  final String? deltaJson;
  final Offset position;
  final double fontSize;
  final Color color;
  final double width;
  final double rotation;

  TextBlock copyWith({
    String? id,
    String? text,
    String? deltaJson,
    Offset? position,
    double? fontSize,
    Color? color,
    double? width,
    double? rotation,
  }) {
    return TextBlock(
      id: id ?? this.id,
      text: text ?? this.text,
      deltaJson: deltaJson ?? this.deltaJson,
      position: position ?? this.position,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      width: width ?? this.width,
      rotation: rotation ?? this.rotation,
    );
  }
}
