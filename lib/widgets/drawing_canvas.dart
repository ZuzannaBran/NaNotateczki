import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/stroke.dart';
import '../state/note_editor_controller.dart';

class DrawingCanvas extends StatelessWidget {
  const DrawingCanvas({
    required this.controller,
    required this.repaintBoundaryKey,
    super.key,
  });

  final NoteEditorController controller;
  final GlobalKey repaintBoundaryKey;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Listener(
          onPointerDown: (event) {
            controller.startStroke(event.localPosition);
          },
          onPointerMove: (event) {
            controller.appendPoint(event.localPosition);
          },
          onPointerUp: (_) {
            controller.endStroke();
          },
          onPointerCancel: (_) {
            controller.endStroke();
          },
          child: RepaintBoundary(
            key: repaintBoundaryKey,
            child: CustomPaint(
              painter: StrokePainter(
                strokes: controller.currentPage.strokes,
                inProgress: controller.inProgressStroke,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class StrokePainter extends CustomPainter {
  StrokePainter({required this.strokes, required this.inProgress});

  final List<Stroke> strokes;
  final Stroke? inProgress;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _paintStroke(canvas, stroke);
    }
    if (inProgress != null) {
      _paintStroke(canvas, inProgress!);
    }
  }

  @override
  bool shouldRepaint(covariant StrokePainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.inProgress != inProgress;
  }

  void _paintStroke(Canvas canvas, Stroke stroke) {
    if (stroke.points.isEmpty) {
      return;
    }

    final paint = Paint()
      ..color = stroke.isEraser ? paperColor : stroke.color
      ..strokeWidth = stroke.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (stroke.points.length == 1) {
      canvas.drawCircle(stroke.points.first, stroke.width / 2, paint);
      return;
    }

    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (final point in stroke.points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }
}
