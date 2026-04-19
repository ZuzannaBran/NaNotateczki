import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/ink_stroke.dart';
import '../../state/editor_controller.dart';

class DrawingCanvas extends StatefulWidget {
  const DrawingCanvas({
    this.allowMultiTouch = true,
    this.interactionEnabled = true,
    this.worldOrigin = Offset.zero,
    super.key,
  });

  final bool allowMultiTouch;
  final bool interactionEnabled;
  final Offset worldOrigin;

  @override
  State<DrawingCanvas> createState() => _DrawingCanvasState();
}

class _DrawingCanvasState extends State<DrawingCanvas> {
  final List<InkPoint> _currentPoints = <InkPoint>[];
  final Set<String> _eraseStrokeIds = <String>{};
  final Set<int> _activePointers = <int>{};
  Offset? _eraserPosition;
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
  Offset? _shapeStart;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final isInkTool = _isInkTool(controller.tool);

    if ((!isInkTool || !widget.interactionEnabled) &&
        _currentPoints.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(_resetCurrent);
        }
      });
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final eraserRadius = controller.tool == DrawingTool.eraserBrush
            ? controller.inkStrokeWidth / 2
            : max(8.0, controller.inkStrokeWidth * 3.0);
        final currentWidth = _effectiveStrokeWidth(
          controller.tool,
          controller.inkStrokeWidth,
        );
        return IgnorePointer(
          ignoring: !isInkTool || !widget.interactionEnabled,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => _onPointerDown(event, controller),
            onPointerMove: (event) => _onPointerMove(event, controller),
            onPointerUp: (event) => _onPointerUp(event, controller),
            onPointerCancel: (event) => _onPointerCancel(event),
            child: CustomPaint(
              painter: _InkPainter(
                strokes: controller.currentPage.inkStrokes,
                currentPoints: _currentPoints,
                currentColor: controller.inkColor,
                currentWidth: currentWidth,
                currentTool: controller.tool,
                worldOrigin: widget.worldOrigin,
                snapHintStart: _snapHintStart,
                snapHintEnd: _snapHintEnd,
                eraserPosition: _eraserPosition,
                eraserRadius: eraserRadius,
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
    EditorController controller,
  ) {
    _activePointers.add(event.pointer);
    if (!widget.allowMultiTouch && _activePointers.length > 1) {
      _resetCurrent();
      return;
    }
    if (!_isInkTool(controller.tool)) {
      return;
    }
    final offset = _toWorld(event.localPosition);
    if (controller.tool.isShape) {
      _shapeStart = offset;
      setState(() {
        _currentPoints
          ..clear()
          ..addAll(
            _buildShapePoints(controller.tool, offset, offset),
          );
      });
      return;
    }
    if (controller.tool == DrawingTool.eraserStroke) {
      _eraseStrokeIds.clear();
      _eraserPosition = offset;
      _eraseAt(offset, controller);
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (controller.tool == DrawingTool.eraserBrush) {
      _eraserPosition = offset;
    }
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
    if (_isSnapTool(controller.tool)) {
      _startSnapTimer(offset);
    }
  }

  void _onPointerMove(
    PointerMoveEvent event,
    EditorController controller,
  ) {
    if (!widget.allowMultiTouch && _activePointers.length > 1) {
      _resetCurrent();
      return;
    }
    if (controller.tool == DrawingTool.eraserStroke) {
      final offset = _toWorld(event.localPosition);
      _eraserPosition = offset;
      _eraseAt(offset, controller);
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (controller.tool.isShape) {
      if (_shapeStart == null) {
        return;
      }
      final offset = _toWorld(event.localPosition);
      setState(() {
        _currentPoints
          ..clear()
          ..addAll(
            _buildShapePoints(controller.tool, _shapeStart!, offset),
          );
      });
      return;
    }
    if (_currentPoints.isEmpty) {
      return;
    }
    final offset = _toWorld(event.localPosition);
    if (_isSnapTool(controller.tool)) {
      _startSnapTimer(offset);
    }
    if (controller.tool == DrawingTool.eraserBrush) {
      setState(() {
        _eraserPosition = offset;
      });
    }
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

  void _onPointerUp(PointerUpEvent event, EditorController controller) {
    _activePointers.remove(event.pointer);
    if (!widget.allowMultiTouch && _activePointers.length > 1) {
      _resetCurrent();
      return;
    }
    if (controller.tool.isShape) {
      if (_currentPoints.isEmpty) {
        _resetCurrent();
        return;
      }
      controller.addInkStroke(
        List<InkPoint>.from(_currentPoints),
        widthOverride: _effectiveStrokeWidth(
          controller.tool,
          controller.inkStrokeWidth,
        ),
      );
      _resetCurrent();
      return;
    }
    if (controller.tool == DrawingTool.eraserStroke) {
      if (_eraseStrokeIds.isNotEmpty) {
        controller.eraseInkStrokesById(_eraseStrokeIds);
        _eraseStrokeIds.clear();
      }
      _eraserPosition = null;
      _resetCurrent();
      return;
    }
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

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _resetCurrent();
  }

  void _resetCurrent() {
    _snapTimer?.cancel();
    _snapHintTimer?.cancel();
    _eraseStrokeIds.clear();
    _eraserPosition = null;
    _snappedStraight = false;
    _snappedRect = false;
    _snappedEllipse = false;
    _snapHintStart = null;
    _snapHintEnd = null;
    _snapAnchor = null;
    _rectFixedCorner = null;
    _ellipseFixedCorner = null;
    _shapeStart = null;
    if (_currentPoints.isEmpty) {
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _currentPoints.clear();
    if (mounted) {
      setState(() {});
    }
  }

  Offset _toWorld(Offset localPosition) {
    return localPosition + widget.worldOrigin;
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

  void _eraseAt(Offset offset, EditorController controller) {
    final radius = max(8.0, controller.inkStrokeWidth * 3.0);
    for (final stroke in controller.currentPage.inkStrokes) {
      if (_eraseStrokeIds.contains(stroke.id)) {
        continue;
      }
      if (_strokeHitTest(stroke, offset, radius)) {
        _eraseStrokeIds.add(stroke.id);
      }
    }
  }

  bool _strokeHitTest(InkStroke stroke, Offset point, double radius) {
    final points = stroke.points;
    if (points.isEmpty) {
      return false;
    }
    final r2 = radius * radius;
    if (points.length == 1) {
      return (points.first.toOffset() - point).distanceSquared <= r2;
    }
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i].toOffset();
      final b = points[i + 1].toOffset();
      if (_distanceSquaredToSegment(point, a, b) <= r2) {
        return true;
      }
    }
    return false;
  }

  double _distanceSquaredToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final ap = p - a;
    final abLen2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (abLen2 == 0) {
      return (p - a).distanceSquared;
    }
    final t = (ap.dx * ab.dx + ap.dy * ab.dy) / abLen2;
    final clamped = t.clamp(0.0, 1.0);
    final closest = Offset(a.dx + ab.dx * clamped, a.dy + ab.dy * clamped);
    return (p - closest).distanceSquared;
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
    return tool.isInk;
  }

  bool _isSnapTool(DrawingTool tool) {
    return tool == DrawingTool.pen || tool == DrawingTool.highlighter;
  }

  double _effectiveStrokeWidth(DrawingTool tool, double baseWidth) {
    if (tool == DrawingTool.highlighter) {
      return baseWidth * 8.0;
    }
    return baseWidth;
  }

  List<InkPoint> _buildShapePoints(
    DrawingTool tool,
    Offset start,
    Offset end,
  ) {
    switch (tool) {
      case DrawingTool.line:
        return [
          InkPoint.fromOffset(start, 1.0),
          InkPoint.fromOffset(end, 1.0),
        ];
      case DrawingTool.arrow:
        return _buildArrowPoints(start, end);
      case DrawingTool.blockArrow:
        return _buildBlockArrowPoints(start, end);
      case DrawingTool.rectangle:
        return _buildRectanglePoints(start, end, 1.0);
      case DrawingTool.square:
        final adjusted = _squareCorner(start, end);
        return _buildRectanglePoints(start, adjusted, 1.0);
      case DrawingTool.triangle:
        return _buildTrianglePoints(start, end);
      case DrawingTool.ellipse:
        return _buildEllipsePoints(start, end, 1.0);
      case DrawingTool.circle:
        final adjusted = _squareCorner(start, end);
        return _buildEllipsePoints(start, adjusted, 1.0);
      default:
        return [
          InkPoint.fromOffset(start, 1.0),
          InkPoint.fromOffset(end, 1.0),
        ];
    }
  }

  Offset _squareCorner(Offset start, Offset end) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final size = max(dx.abs(), dy.abs());
    final sx = dx == 0 ? 1.0 : dx.sign;
    final sy = dy == 0 ? 1.0 : dy.sign;
    return Offset(start.dx + size * sx, start.dy + size * sy);
  }

  List<InkPoint> _buildArrowPoints(Offset start, Offset end) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = sqrt(dx * dx + dy * dy);
    if (length < 1.0) {
      return [
        InkPoint.fromOffset(start, 1.0),
        InkPoint.fromOffset(end, 1.0),
      ];
    }
    final dir = Offset(dx / length, dy / length);
    final normal = Offset(-dir.dy, dir.dx);
    final headLength = max(12.0, length * 0.18);
    final headWidth = headLength * 0.55;
    final left = end - dir * headLength + normal * headWidth;
    final right = end - dir * headLength - normal * headWidth;
    return [
      InkPoint.fromOffset(start, 1.0),
      InkPoint.fromOffset(end, 1.0),
      InkPoint.fromOffset(left, 1.0),
      InkPoint.fromOffset(end, 1.0),
      InkPoint.fromOffset(right, 1.0),
    ];
  }

  List<InkPoint> _buildTrianglePoints(Offset start, Offset end) {
    final left = min(start.dx, end.dx);
    final right = max(start.dx, end.dx);
    final top = min(start.dy, end.dy);
    final bottom = max(start.dy, end.dy);
    final midX = (left + right) / 2;
    final p1 = Offset(left, bottom);
    final p2 = Offset(right, bottom);
    final p3 = Offset(midX, top);
    return [
      InkPoint.fromOffset(p1, 1.0),
      InkPoint.fromOffset(p2, 1.0),
      InkPoint.fromOffset(p3, 1.0),
      InkPoint.fromOffset(p1, 1.0),
    ];
  }

  List<InkPoint> _buildBlockArrowPoints(Offset start, Offset end) {
    final left = min(start.dx, end.dx);
    final right = max(start.dx, end.dx);
    final top = min(start.dy, end.dy);
    final bottom = max(start.dy, end.dy);
    final width = right - left;
    final height = bottom - top;
    if (width < 8 || height < 8) {
      return _buildRectanglePoints(Offset(left, top), Offset(right, bottom), 1.0);
    }

    final minBodyWidth = max(6.0, width * 0.15);
    var headWidth = max(12.0, width * 0.35);
    if (headWidth > width - minBodyWidth) {
      headWidth = width - minBodyWidth;
    }
    if (headWidth <= 0) {
      return _buildRectanglePoints(Offset(left, top), Offset(right, bottom), 1.0);
    }
    final bodyRight = right - headWidth;
    final midY = (top + bottom) / 2;
    final headHalfHeight = height * 0.8;
    final headTop = midY - headHalfHeight;
    final headBottom = midY + headHalfHeight;
    final p1 = Offset(left, top);
    final p2 = Offset(bodyRight, top);
    final p3 = Offset(right, midY);
    final p4 = Offset(bodyRight, bottom);
    final p5 = Offset(left, bottom);
    final p6 = Offset(bodyRight, headBottom);
    final p7 = Offset(bodyRight, headTop);
    return [
      InkPoint.fromOffset(p1, 1.0),
      InkPoint.fromOffset(p2, 1.0),
      InkPoint.fromOffset(p7, 1.0),
      InkPoint.fromOffset(p3, 1.0),
      InkPoint.fromOffset(p6, 1.0),
      InkPoint.fromOffset(p4, 1.0),
      InkPoint.fromOffset(p5, 1.0),
      InkPoint.fromOffset(p1, 1.0),
    ];
  }
}

class _InkPainter extends CustomPainter {
  _InkPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentColor,
    required this.currentWidth,
    required this.currentTool,
    required this.worldOrigin,
    this.snapHintStart,
    this.snapHintEnd,
    this.eraserPosition,
    this.eraserRadius,
  });

  final List<InkStroke> strokes;
  final List<InkPoint> currentPoints;
  final Color currentColor;
  final double currentWidth;
  final DrawingTool currentTool;
  final Offset worldOrigin;
  final Offset? snapHintStart;
  final Offset? snapHintEnd;
  final Offset? eraserPosition;
  final double? eraserRadius;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
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
      canvas.drawLine(
        snapHintStart! - worldOrigin,
        snapHintEnd! - worldOrigin,
        paint,
      );
    }

    if (eraserPosition != null &&
        (currentTool == DrawingTool.eraserBrush ||
            currentTool == DrawingTool.eraserStroke)) {
      final radius = eraserRadius ?? 12.0;
      final ringPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawCircle(eraserPosition! - worldOrigin, radius, ringPaint);
    }
    canvas.restore();
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
      ..strokeCap = tool == DrawingTool.highlighter
          ? StrokeCap.square
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    if (tool == DrawingTool.eraserBrush) {
      paint
        ..color = Colors.transparent
        ..blendMode = BlendMode.clear;
    } else {
      paint.color = _toolColor(color, tool);
    }

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final offset = points[i].toOffset() - worldOrigin;
      if (i == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }
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
        oldDelegate.snapHintEnd != snapHintEnd ||
        oldDelegate.eraserPosition != eraserPosition ||
        oldDelegate.eraserRadius != eraserRadius;
  }
}
