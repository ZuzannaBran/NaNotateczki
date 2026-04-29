import 'dart:ui';

class ImageBlock {
  ImageBlock({
    required this.id,
    required this.path,
    required this.ocrText,
    required this.position,
    required this.width,
    required this.height,
    this.rotation = 0.0,
  });

  final String id;
  final String path;
  final String ocrText;
  final Offset position;
  final double width;
  final double height;
  final double rotation;

  ImageBlock copyWith({
    String? id,
    String? path,
    String? ocrText,
    Offset? position,
    double? width,
    double? height,
    double? rotation,
  }) {
    return ImageBlock(
      id: id ?? this.id,
      path: path ?? this.path,
      ocrText: ocrText ?? this.ocrText,
      position: position ?? this.position,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
    );
  }
}
