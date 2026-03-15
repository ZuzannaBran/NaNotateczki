import 'dart:ui';

import 'drawing_tool.dart';

class Stroke {
  Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.tool,
  });

  final List<Offset> points;
  final Color color;
  final double width;
  final DrawingTool tool;

  bool get isEraser => tool == DrawingTool.eraser;
}
