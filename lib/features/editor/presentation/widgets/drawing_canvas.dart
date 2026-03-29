import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/ink_stroke.dart';
import '../../state/editor_controller.dart';

class DrawingCanvas extends StatefulWidget {
  const DrawingCanvas({super.key});

  @override
  State<DrawingCanvas> createState() => _DrawingCanvasState();
}

class _DrawingCanvasState extends State<DrawingCanvas> {
  final List<InkPoint> _currentPoints = <InkPoint>[];
  Timer? _snapTimer;
  bool _snappedStraight = false;
  bool _snappedRect = false;
  bool _snappedEllipse = false;
  Timer? _snapHintTimer;
  Offset? _snapHintStart;
  Offset? _snapHintEnd;
  Offset? _snapAnchor;
  Offset? _rectFixedCorner;
  Offset? _ellipseFixedCorner;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final isInkTool = _isInkTool(controller.tool);

    if (!isInkTool && _currentPoints.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(_resetCurrent);
        }
      });
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return IgnorePointer(
          ignoring: !isInkTool,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => _onPointerDown(event, size, controller),
            onPointerMove: (event) => _onPointerMove(event, size),
            onPointerUp: (event) => _onPointerUp(controller),
            onPointerCancel: (_) => _resetCurrent(),
            child: CustomPaint(
              painter: _InkPainter(
                strokes: controller.currentPage.inkStrokes,
                currentPoints: _currentPoints,
                currentColor: controller.inkColor,
                currentWidth: controller.tool == DrawingTool.highlighter
                  ? controller.inkStrokeWidth * 8.0
                    : controller.inkStrokeWidth,
                currentTool: controller.tool,
                snapHintStart: _snapHintStart,
                snapHintEnd: _snapHintEnd,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }

  void _onPointerDown(
    PointerDownEvent event,
    Size size,
    EditorController controller,
  ) {
    if (!_isInkTool(controller.tool)) {
      return;
    }
    final offset = _clamp(event.localPosition, size);
    setState(() {
      _currentPoints
        ..clear()
        ..add(
          InkPoint.fromOffset(
            offset,
            1.0,
          ),
        );
      _snappedStraight = false;
      _snappedRect = false;
      _snappedEllipse = false;
      _rectFixedCorner = null;
      _ellipseFixedCorner = null;
    });
    _startSnapTimer(offset);
  }

  void _onPointerMove(PointerMoveEvent event, Size size) {
    if (_currentPoints.isEmpty) {
      return;
    }
    final offset = _clamp(event.localPosition, size);
    _startSnapTimer(offset);
    if (_snappedStraight) {
      setState(() {
        if (_currentPoints.length >= 2) {
          _currentPoints[_currentPoints.length - 1] = InkPoint.fromOffset(
            offset,
            1.0,
          );
        }
      });
      return;
    }
    if (_snappedRect) {
      setState(() {
        if (_currentPoints.length == 5) {
          // Update rectangle using fixed far corner and moving hold point
          final fixed = _rectFixedCorner ?? _currentPoints.first.toOffset();
          final points = _buildRectanglePoints(fixed, offset, event.pressure);
          _currentPoints
            ..clear()
            ..addAll(points);
        }
      });
      return;
    }
    if (_snappedEllipse) {
      setState(() {
        final fixed = _ellipseFixedCorner ?? _currentPoints.first.toOffset();
        _currentPoints
          ..clear()
          ..addAll(_buildEllipsePoints(fixed, offset, event.pressure));
      });
      return;
    }
    if (!_shouldAddPoint(offset)) {
      return;
    }
    setState(() {
      _currentPoints.add(
        InkPoint.fromOffset(
          offset,
          1.0,
        ),
      );
    });
  }

  void _onPointerUp(EditorController controller) {
    if (_currentPoints.isEmpty) {
      return;
    }
    _snapTimer?.cancel();
    if (_currentPoints.length == 1) {
      final point = _currentPoints.first;
      _currentPoints.add(
        InkPoint(
          dx: point.dx + 0.5,
          dy: point.dy,
          pressure: point.pressure,
        ),
      );
    }
    controller.addInkStroke(List<InkPoint>.from(_currentPoints));
    _resetCurrent();
  }

  void _resetCurrent() {
    _snapTimer?.cancel();
    _snapHintTimer?.cancel();
    if (_currentPoints.isEmpty) {
      return;
    }
    _currentPoints.clear();
    _snappedStraight = false;
    _snappedRect = false;
    _snappedEllipse = false;
    _snapHintStart = null;
    _snapHintEnd = null;
    _snapAnchor = null;
    _rectFixedCorner = null;
    _ellipseFixedCorner = null;
    if (mounted) {
      setState(() {});
    }
  }

  Offset _clamp(Offset offset, Size size) {
    return Offset(
      min(max(0, offset.dx), size.width),
      min(max(0, offset.dy), size.height),
    );
  }


  bool _shouldAddPoint(Offset offset) {
    if (_currentPoints.isEmpty) {
      return true;
    }
    final last = _currentPoints.last.toOffset();
    return (offset - last).distanceSquared > 0.5;
  }

  void _startSnapTimer(Offset offset) {
    const jitterTolerance = 20.0;
    if (_snapAnchor == null || (offset - _snapAnchor!).distance > jitterTolerance) {
      _snapAnchor = offset;
      _snapTimer?.cancel();
      _snapTimer = Timer(const Duration(milliseconds: 1200), _snapToShape);
    }
  }

  void _snapToShape() {
    if (_currentPoints.length < 2 || _snappedStraight || _snappedRect || _snappedEllipse) {
      return;
    }
    final first = _currentPoints.first.toOffset();
    final last = _currentPoints.last.toOffset();
    if (_isRoughlyStraight(first, last, _currentPoints)) {
      final firstPoint = _currentPoints.first;
      final lastPoint = _currentPoints.last;
      _snappedStraight = true;
      setState(() {
        _currentPoints
          ..clear()
          ..add(firstPoint)
          ..add(lastPoint);
        _snapHintStart = first;
        _snapHintEnd = last;
      });
      _clearSnapHintSoon();
      return;
    }

    if (_isRoughlyEllipse(_currentPoints)) {
      final holdPoint = _snapAnchor ?? last;
      final fixedCorner = _findFarthestCorner(_currentPoints, holdPoint);
      _snappedEllipse = true;
      _ellipseFixedCorner = fixedCorner;
      setState(() {
        _currentPoints
          ..clear()
          ..addAll(_buildEllipsePoints(fixedCorner, holdPoint, 0.5));
        _snapHintStart = null;
        _snapHintEnd = null;
      });
      _clearSnapHintSoon();
      return;
    }

    if (_isRoughlyRectangle(_currentPoints)) {
      final holdPoint = _snapAnchor ?? last;
      final fixedCorner = _findFarthestCorner(_currentPoints, holdPoint);
      _snappedRect = true;
      _rectFixedCorner = fixedCorner;
      setState(() {
        _currentPoints
          ..clear()
          ..addAll(_buildRectanglePoints(fixedCorner, holdPoint, 0.5));
        _snapHintStart = fixedCorner;
        _snapHintEnd = holdPoint;
      });
      _clearSnapHintSoon();
      return;
    }
  }

  void _clearSnapHintSoon() {
    _snapHintTimer?.cancel();
    _snapHintTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _snapHintStart = null;
        _snapHintEnd = null;
      });
    });
  }

  bool _isRoughlyStraight(
    Offset start,
    Offset end,
    List<InkPoint> points,
  ) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = sqrt(dx * dx + dy * dy);
    if (length < 2) {
      return false;
    }
    final maxDistance = max(8.0, length * 0.08);
    for (final point in points) {
      final offset = point.toOffset();
      final distance = ((dy * offset.dx - dx * offset.dy + end.dx * start.dy - end.dy * start.dx).abs()) / length;
      if (distance > maxDistance) {
        return false;
      }
    }
    return true;
  }

  bool _isRoughlyRectangle(List<InkPoint> points) {
    if (points.length < 4) {
      return false;
    }
    final offsets = points.map((point) => point.toOffset()).toList();
    final minX = offsets.map((item) => item.dx).reduce(min);
    final maxX = offsets.map((item) => item.dx).reduce(max);
    final minY = offsets.map((item) => item.dy).reduce(min);
    final maxY = offsets.map((item) => item.dy).reduce(max);
    final width = maxX - minX;
    final height = maxY - minY;
    if (width < 6 || height < 6) {
      return false;
    }
    final maxDistance = max(10.0, min(width, height) * 0.25);
    for (final offset in offsets) {
      final dx = min((offset.dx - minX).abs(), (offset.dx - maxX).abs());
      final dy = min((offset.dy - minY).abs(), (offset.dy - maxY).abs());
      if (min(dx, dy) > maxDistance) {
        return false;
      }
    }
    return true;
  }

  bool _isRoughlyEllipse(List<InkPoint> points) {
    if (points.length < 6) {
      return false;
    }
    final offsets = points.map((point) => point.toOffset()).toList();
    final minX = offsets.map((item) => item.dx).reduce(min);
    final maxX = offsets.map((item) => item.dx).reduce(max);
    final minY = offsets.map((item) => item.dy).reduce(min);
    final maxY = offsets.map((item) => item.dy).reduce(max);
    final width = maxX - minX;
    final height = maxY - minY;
    if (width < 6 || height < 6) {
      return false;
    }
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    final rx = width / 2;
    final ry = height / 2;
    if (rx == 0 || ry == 0) {
      return false;
    }
    var nearBoundary = 0;
    for (final offset in offsets) {
      final nx = (offset.dx - cx) / rx;
      final ny = (offset.dy - cy) / ry;
      final v = nx * nx + ny * ny;
      if ((v - 1).abs() <= 0.35) {
        nearBoundary++;
      }
    }
    return nearBoundary >= (offsets.length * 0.6);
  }

  List<InkPoint> _buildRectanglePoints(
    Offset start,
    Offset end,
    double pressure,
  ) {
    final p1 = InkPoint.fromOffset(start, 1.0);
    final p2 = InkPoint.fromOffset(Offset(end.dx, start.dy), 1.0);
    final p3 = InkPoint.fromOffset(end, 1.0);
    final p4 = InkPoint.fromOffset(Offset(start.dx, end.dy), 1.0);
    return [p1, p2, p3, p4, p1];
  }

  List<InkPoint> _buildEllipsePoints(
    Offset fixedCorner,
    Offset holdPoint,
    double pressure,
  ) {
    final left = min(fixedCorner.dx, holdPoint.dx);
    final right = max(fixedCorner.dx, holdPoint.dx);
    final top = min(fixedCorner.dy, holdPoint.dy);
    final bottom = max(fixedCorner.dy, holdPoint.dy);
    final cx = (left + right) / 2;
    final cy = (top + bottom) / 2;
    final rx = (right - left) / 2;
    final ry = (bottom - top) / 2;
    const segments = 36;
    final points = <InkPoint>[];
    for (var i = 0; i <= segments; i++) {
      final t = (i / segments) * 2 * pi;
      final x = cx + rx * cos(t);
      final y = cy + ry * sin(t);
      points.add(InkPoint.fromOffset(Offset(x, y), 1.0));
    }
    return points;
  }

  Offset _findFarthestCorner(List<InkPoint> points, Offset holdPoint) {
    final offsets = points.map((point) => point.toOffset()).toList();
    final minX = offsets.map((item) => item.dx).reduce(min);
    final maxX = offsets.map((item) => item.dx).reduce(max);
    final minY = offsets.map((item) => item.dy).reduce(min);
    final maxY = offsets.map((item) => item.dy).reduce(max);
    final corners = <Offset>[
      Offset(minX, minY),
      Offset(maxX, minY),
      Offset(maxX, maxY),
      Offset(minX, maxY),
    ];
    Offset farthest = corners.first;
    double maxDistance = 0;
    for (final corner in corners) {
      final distance = (corner - holdPoint).distanceSquared;
      if (distance > maxDistance) {
        maxDistance = distance;
        farthest = corner;
      }
    }
    return farthest;
  }

  bool _isInkTool(DrawingTool tool) {
    return tool == DrawingTool.pen || tool == DrawingTool.highlighter;
  }
}

class _InkPainter extends CustomPainter {
  _InkPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentColor,
    required this.currentWidth,
    required this.currentTool,
    this.snapHintStart,
    this.snapHintEnd,
  });

  final List<InkStroke> strokes;
  final List<InkPoint> currentPoints;
  final Color currentColor;
  final double currentWidth;
  final DrawingTool currentTool;
  final Offset? snapHintStart;
  final Offset? snapHintEnd;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _drawStroke(
        canvas,
        stroke.points,
        stroke.color,
        stroke.width,
        stroke.tool,
      );
    }

    if (currentPoints.isNotEmpty) {
      _drawStroke(
        canvas,
        currentPoints,
        currentColor,
        currentWidth,
        currentTool,
      );
    }

    if (snapHintStart != null && snapHintEnd != null) {
      final paint = Paint()
        ..color = currentColor.withValues(alpha: 0.35)
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = currentWidth + 1.5;
      canvas.drawLine(snapHintStart!, snapHintEnd!, paint);
    }
  }

  void _drawStroke(
    Canvas canvas,
    List<InkPoint> points,
    Color color,
    double width,
    DrawingTool tool,
  ) {
    if (points.isEmpty) {
      return;
    }
    final paint = Paint()
      ..color = _toolColor(color, tool)
      ..strokeCap = tool == DrawingTool.highlighter
          ? StrokeCap.square
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final offset = points[i].toOffset();
      if (i == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }
    // Zamknij ścieżkę jeśli pierwszy i ostatni punkt są takie same.
    if (points.first.dx == points.last.dx && points.first.dy == points.last.dy) {
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  Color _toolColor(Color base, DrawingTool tool) {
    if (tool == DrawingTool.highlighter) {
      return base.withValues(alpha: 0.5);
    }
    return base;
  }

  @override
  bool shouldRepaint(covariant _InkPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.currentPoints != currentPoints ||
        oldDelegate.currentColor != currentColor ||
        oldDelegate.currentWidth != currentWidth ||
      oldDelegate.currentTool != currentTool ||
        oldDelegate.snapHintStart != snapHintStart ||
        oldDelegate.snapHintEnd != snapHintEnd;
  }
}
