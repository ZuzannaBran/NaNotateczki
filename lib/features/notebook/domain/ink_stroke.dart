import 'dart:ui';

import 'drawing_tool.dart';

class InkStroke {
  InkStroke({
    required this.id,
    required this.points,
    required this.color,
    required this.width,
    required this.tool,
  });

  final String id;
  final List<InkPoint> points;
  final Color color;
  final double width;
  final DrawingTool tool;

  InkStroke copyWith({
    String? id,
    List<InkPoint>? points,
    Color? color,
    double? width,
    DrawingTool? tool,
  }) {
    return InkStroke(
      id: id ?? this.id,
      points: points ?? this.points,
      color: color ?? this.color,
      width: width ?? this.width,
      tool: tool ?? this.tool,
    );
  }
}

class InkPoint {
  const InkPoint({
    required this.dx,
    required this.dy,
    required this.pressure,
  });

  final double dx;
  final double dy;
  final double pressure;

  factory InkPoint.fromOffset(Offset offset, double pressure) {
    return InkPoint(dx: offset.dx, dy: offset.dy, pressure: pressure);
  }

  Offset toOffset() => Offset(dx, dy);
}
