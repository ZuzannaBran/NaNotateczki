import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../notebook/domain/shape.dart';
import '../../../notebook/domain/stroke.dart';
import '../../../notebook/domain/stroke_point.dart';
import '../../state/editor_controller.dart';

class DrawingCanvas extends StatelessWidget {
  const DrawingCanvas({required this.controller, super.key});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Listener(
          onPointerDown: (event) {
            controller.handlePointerDown(event.localPosition, event.pressure);
          },
          onPointerMove: (event) {
            controller.handlePointerMove(event.localPosition, event.pressure);
          },
          onPointerUp: (_) {
            controller.handlePointerUp();
          },
          onPointerCancel: (_) {
            controller.handlePointerUp();
          },
          child: CustomPaint(
            painter: StrokePainter(
              strokes: controller.currentPage.strokes,
              shapes: controller.currentPage.shapes,
              inProgress: controller.inProgressStroke,
              inProgressShape: controller.inProgressShape,
              selectionBounds: controller.selectionBounds,
              lassoPoints: controller.lassoPoints,
              isSelecting: controller.isSelecting,
              selectedStrokeIds: controller.selectedStrokeIds,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class StrokePainter extends CustomPainter {
  StrokePainter({
    required this.strokes,
    required this.shapes,
    required this.inProgress,
    required this.inProgressShape,
    required this.selectionBounds,
    required this.lassoPoints,
    required this.isSelecting,
    required this.selectedStrokeIds,
  });

  final List<Stroke> strokes;
  final List<Shape> shapes;
  final Stroke? inProgress;
  final Shape? inProgressShape;
  final Rect? selectionBounds;
  final List<Offset> lassoPoints;
  final bool isSelecting;
  final Set<String> selectedStrokeIds;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _paintStroke(
        canvas,
        stroke,
        highlight: selectedStrokeIds.contains(stroke.id),
      );
    }
    for (final shape in shapes) {
      _paintShape(canvas, shape);
    }
    if (inProgress != null) {
      _paintStroke(canvas, inProgress!);
    }
    if (inProgressShape != null) {
      _paintShape(canvas, inProgressShape!);
    }
    if (selectionBounds != null) {
      _paintSelectionBounds(canvas, selectionBounds!);
    }
    if (isSelecting && lassoPoints.isNotEmpty) {
      _paintLasso(canvas, lassoPoints);
    }
  }

  @override
  bool shouldRepaint(covariant StrokePainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.inProgress != inProgress ||
        oldDelegate.shapes != shapes ||
        oldDelegate.inProgressShape != inProgressShape ||
        oldDelegate.selectionBounds != selectionBounds ||
        oldDelegate.lassoPoints != lassoPoints ||
        oldDelegate.isSelecting != isSelecting ||
        oldDelegate.selectedStrokeIds != selectedStrokeIds;
  }

  void _paintStroke(Canvas canvas, Stroke stroke, {bool highlight = false}) {
    if (stroke.points.isEmpty) {
      return;
    }

    final paint = Paint()
      ..color = stroke.isEraser ? AppColors.paper : stroke.color
      ..strokeWidth = stroke.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = stroke.isHighlighter
          ? BlendMode.multiply
          : BlendMode.srcOver;

    if (highlight) {
      paint
        ..strokeWidth = stroke.width + 2
        ..color = AppColors.inkBlack.withValues(alpha: 0.12);
    }

    if (stroke.points.length == 1) {
      final point = stroke.points.first;
      canvas.drawCircle(Offset(point.dx, point.dy), stroke.width / 2, paint);
      return;
    }

    final path = _smoothPath(stroke.points);
    canvas.drawPath(path, paint);
  }

  Path _smoothPath(List<StrokePoint> points) {
    final offsets = points.map((p) => Offset(p.dx, p.dy)).toList();
    if (offsets.length < 2) {
      return Path()..addOval(Rect.fromCircle(center: offsets.first, radius: 1));
    }

    final path = Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (var i = 1; i < offsets.length; i++) {
      final current = offsets[i];
      final previous = offsets[i - 1];
      final mid = Offset(
        (current.dx + previous.dx) / 2,
        (current.dy + previous.dy) / 2,
      );
      path.quadraticBezierTo(previous.dx, previous.dy, mid.dx, mid.dy);
    }
    path.lineTo(offsets.last.dx, offsets.last.dy);
    return path;
  }

  void _paintSelectionBounds(Canvas canvas, Rect bounds) {
    final paint = Paint()
      ..color = AppColors.inkBlack.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(bounds, paint);
  }

  void _paintLasso(Canvas canvas, List<Offset> points) {
    if (points.length < 2) {
      return;
    }
    final paint = Paint()
      ..color = AppColors.inkBlack.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  void _paintShape(Canvas canvas, Shape shape) {
    final paint = Paint()
      ..color = shape.color
      ..strokeWidth = shape.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (shape.type) {
      case ShapeType.line:
        canvas.drawLine(shape.start, shape.end, paint);
        break;
      case ShapeType.rectangle:
        canvas.drawRect(shape.bounds, paint);
        break;
      case ShapeType.ellipse:
        canvas.drawOval(shape.bounds, paint);
        break;
    }
  }
}
