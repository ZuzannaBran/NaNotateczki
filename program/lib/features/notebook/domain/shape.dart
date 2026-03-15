import 'dart:ui';

enum ShapeType { line, rectangle, ellipse }

class Shape {
  Shape({
    required this.id,
    required this.type,
    required this.color,
    required this.width,
    required this.start,
    required this.end,
  });

  final String id;
  final ShapeType type;
  final Color color;
  final double width;
  final Offset start;
  final Offset end;

  Rect get bounds {
    final left = start.dx < end.dx ? start.dx : end.dx;
    final right = start.dx > end.dx ? start.dx : end.dx;
    final top = start.dy < end.dy ? start.dy : end.dy;
    final bottom = start.dy > end.dy ? start.dy : end.dy;
    return Rect.fromLTRB(left, top, right, bottom);
  }
}
