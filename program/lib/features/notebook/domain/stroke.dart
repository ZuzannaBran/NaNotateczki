import 'dart:ui';

import 'drawing_tool.dart';
import 'stroke_point.dart';

class Stroke {
  Stroke({
    required this.id,
    required this.points,
    required this.color,
    required this.width,
    required this.tool,
  });

  final String id;
  final List<StrokePoint> points;
  final Color color;
  final double width;
  final DrawingTool tool;

  bool get isEraser => tool == DrawingTool.eraser;
  bool get isHighlighter => tool == DrawingTool.highlighter;
}
