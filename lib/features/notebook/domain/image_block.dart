import 'dart:typed_data';
import 'dart:ui';

class ImageBlock {
  ImageBlock({
    required this.id,
    required this.path,
    required this.ocrText,
    required this.position,
    required this.width,
    required this.height,
    this.bytes,
    this.imageExt,
    this.imageMime,
    this.rotation = 0.0,
    this.cropLeft = 0.0,
    this.cropTop = 0.0,
    this.cropRight = 1.0,
    this.cropBottom = 1.0,
  });

  final String id;
  final String path;
  final String ocrText;
  final Offset position;
  final double width;
  final double height;
  final Uint8List? bytes;
  final String? imageExt;
  final String? imageMime;
  final double rotation;
  final double cropLeft;
  final double cropTop;
  final double cropRight;
  final double cropBottom;

  ImageBlock copyWith({
    String? id,
    String? path,
    String? ocrText,
    Offset? position,
    double? width,
    double? height,
    Uint8List? bytes,
    String? imageExt,
    String? imageMime,
    double? rotation,
    double? cropLeft,
    double? cropTop,
    double? cropRight,
    double? cropBottom,
  }) {
    return ImageBlock(
      id: id ?? this.id,
      path: path ?? this.path,
      ocrText: ocrText ?? this.ocrText,
      position: position ?? this.position,
      width: width ?? this.width,
      height: height ?? this.height,
      bytes: bytes ?? this.bytes,
      imageExt: imageExt ?? this.imageExt,
      imageMime: imageMime ?? this.imageMime,
      rotation: rotation ?? this.rotation,
      cropLeft: cropLeft ?? this.cropLeft,
      cropTop: cropTop ?? this.cropTop,
      cropRight: cropRight ?? this.cropRight,
      cropBottom: cropBottom ?? this.cropBottom,
    );
  }
}
