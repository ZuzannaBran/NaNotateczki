import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/ink_stroke.dart';
import '../../state/editor_controller.dart';

/// Editable control points for persisted geometric ink strokes.
class ShapeEditGeometry {
  static Rect bounds(InkStroke stroke) {
    final points = stroke.points.map((point) => point.toOffset()).toList();
    if (points.isEmpty) {
      return Rect.zero;
    }
    return Rect.fromLTRB(
      points.map((point) => point.dx).reduce(math.min),
      points.map((point) => point.dy).reduce(math.min),
      points.map((point) => point.dx).reduce(math.max),
      points.map((point) => point.dy).reduce(math.max),
    );
  }

  static List<Offset> handles(InkStroke stroke) {
    final points = stroke.points.map((point) => point.toOffset()).toList();
    if (points.isEmpty) {
      return const [];
    }
    final rect = bounds(stroke);
    switch (stroke.tool) {
      case DrawingTool.line:
      case DrawingTool.arrow:
        return points.length > 1 ? [points.first, points[1]] : points;
      case DrawingTool.rectangle:
      case DrawingTool.square:
        return [
          rect.topLeft,
          rect.topRight,
          rect.bottomRight,
          rect.bottomLeft,
        ];
      case DrawingTool.triangle:
        return points.take(3).toList();
      case DrawingTool.ellipse:
      case DrawingTool.circle:
        return [
          rect.topCenter,
          rect.centerRight,
          rect.bottomCenter,
          rect.centerLeft,
        ];
      case DrawingTool.blockArrow:
        return [rect.topLeft, rect.centerRight, rect.bottomLeft];
      default:
        return const [];
    }
  }

  static InkStroke moved(InkStroke stroke, Offset delta) {
    return stroke.copyWith(
      points: [
        for (final point in stroke.points)
          InkPoint(
            dx: point.dx + delta.dx,
            dy: point.dy + delta.dy,
            pressure: point.pressure,
          ),
      ],
    );
  }

  static InkStroke resized(
    InkStroke stroke,
    int handleIndex,
    Offset delta,
  ) {
    final controlPoints = handles(stroke);
    if (handleIndex < 0 || handleIndex >= controlPoints.length) {
      return stroke;
    }
    final target = controlPoints[handleIndex] + delta;
    final rect = bounds(stroke);
    List<Offset> points;
    switch (stroke.tool) {
      case DrawingTool.line:
        points = stroke.points.map((point) => point.toOffset()).toList();
        points[handleIndex] = target;
      case DrawingTool.arrow:
        final start = handleIndex == 0 ? target : controlPoints[0];
        final end = handleIndex == 1 ? target : controlPoints[1];
        final direction = end - start;
        final length = direction.distance;
        if (length < 1) {
          points = [start, end];
        } else {
          final unit = direction / length;
          final normal = Offset(-unit.dy, unit.dx);
          final head = math.max(12.0, length * 0.18);
          points = [
            start,
            end,
            end - unit * head + normal * (head * 0.55),
            end,
            end - unit * head - normal * (head * 0.55),
          ];
        }
      case DrawingTool.triangle:
        points = [
          ...stroke.points.take(3).map((point) => point.toOffset()),
        ];
        points[handleIndex] = target;
        points.add(points.first);
      case DrawingTool.rectangle:
      case DrawingTool.square:
        final opposite = controlPoints[(handleIndex + 2) % 4];
        var corner = target;
        if (stroke.tool == DrawingTool.square) {
          final distance = corner - opposite;
          final extent = math.max(distance.dx.abs(), distance.dy.abs());
          corner = opposite + Offset(
            (distance.dx < 0 ? -1 : 1) * extent,
            (distance.dy < 0 ? -1 : 1) * extent,
          );
        }
        final updated = Rect.fromPoints(opposite, corner);
        points = _rectangle(updated);
      case DrawingTool.ellipse:
      case DrawingTool.circle:
        var left = rect.left;
        var top = rect.top;
        var right = rect.right;
        var bottom = rect.bottom;
        switch (handleIndex) {
          case 0:
            top = math.min(target.dy, bottom - 2);
          case 1:
            right = math.max(target.dx, left + 2);
          case 2:
            bottom = math.max(target.dy, top + 2);
          case 3:
            left = math.min(target.dx, right - 2);
        }
        if (stroke.tool == DrawingTool.circle) {
          final diameter = handleIndex.isEven
              ? bottom - top
              : right - left;
          if (handleIndex.isEven) {
            left = rect.center.dx - diameter / 2;
            right = rect.center.dx + diameter / 2;
          } else {
            top = rect.center.dy - diameter / 2;
            bottom = rect.center.dy + diameter / 2;
          }
        }
        points = _ellipse(Rect.fromLTRB(left, top, right, bottom));
      case DrawingTool.blockArrow:
        var left = rect.left;
        var top = rect.top;
        var right = rect.right;
        var bottom = rect.bottom;
        if (handleIndex == 0) {
          left = math.min(target.dx, right - 2);
          top = math.min(target.dy, bottom - 2);
        } else if (handleIndex == 1) {
          right = math.max(target.dx, left + 2);
          top += delta.dy;
          bottom += delta.dy;
        } else {
          left = math.min(target.dx, right - 2);
          bottom = math.max(target.dy, top + 2);
        }
        points = _blockArrow(Rect.fromLTRB(left, top, right, bottom));
      default:
        return stroke;
    }
    return stroke.copyWith(
      points: [
        for (final point in points) InkPoint.fromOffset(point, 1.0),
      ],
    );
  }

  static bool hitTest(InkStroke stroke, Offset point, {double radius = 12}) {
    final points = stroke.points.map((item) => item.toOffset()).toList();
    if (points.isEmpty) {
      return false;
    }
    for (final handle in handles(stroke)) {
      if ((handle - point).distance <= radius) {
        return true;
      }
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final item in points.skip(1)) {
      path.lineTo(item.dx, item.dy);
    }
    final closed = stroke.tool != DrawingTool.line &&
        stroke.tool != DrawingTool.arrow;
    if (closed) {
      path.close();
      if (path.contains(point)) {
        return true;
      }
    }
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final segment = b - a;
      final squared = segment.distanceSquared;
      final t = squared == 0
          ? 0.0
          : (((point - a).dx * segment.dx +
                    (point - a).dy * segment.dy) /
                squared).clamp(0.0, 1.0).toDouble();
      if ((point - (a + segment * t)).distance <= radius) {
        return true;
      }
    }
    return false;
  }

  static List<Offset> _rectangle(Rect rect) => [
    rect.topLeft,
    rect.topRight,
    rect.bottomRight,
    rect.bottomLeft,
    rect.topLeft,
  ];

  static List<Offset> _ellipse(Rect rect) {
    return [
      for (var i = 0; i <= 36; i++)
        Offset(
          rect.center.dx + rect.width / 2 * math.cos(i * math.pi / 18),
          rect.center.dy + rect.height / 2 * math.sin(i * math.pi / 18),
        ),
    ];
  }

  static List<Offset> _blockArrow(Rect rect) {
    final width = rect.width;
    final height = rect.height;
    if (width < 8 || height < 8) {
      return _rectangle(rect);
    }
    final headWidth = math.min(
      math.max(12.0, width * 0.35),
      width - math.max(6.0, width * 0.15),
    );
    final shoulder = rect.right - headWidth;
    final headTop = rect.center.dy - height * 0.8;
    final headBottom = rect.center.dy + height * 0.8;
    return [
      rect.topLeft,
      Offset(shoulder, rect.top),
      Offset(shoulder, headTop),
      rect.centerRight,
      Offset(shoulder, headBottom),
      Offset(shoulder, rect.bottom),
      rect.bottomLeft,
      rect.topLeft,
    ];
  }
}

/// Pointer-only overlay: empty page area remains available to other tools.
class ShapeEditOverlay extends StatefulWidget {
  const ShapeEditOverlay({
    required this.controller,
    required this.stroke,
    required this.pageIndex,
    required this.origin,
    required this.interactionEnabled,
    super.key,
  });

  final EditorController controller;
  final InkStroke stroke;
  final int pageIndex;
  final Offset origin;
  final bool interactionEnabled;

  @override
  State<ShapeEditOverlay> createState() => _ShapeEditOverlayState();
}

class _ShapeEditOverlayState extends State<ShapeEditOverlay> {
  int? _pointer;
  int? _handle;
  Offset? _start;
  InkStroke? _before;

  InkStroke get _displayStroke => ShapeEditGeometry.moved(
    widget.stroke,
    -widget.origin,
  );

  @override
  void dispose() {
    if (_pointer != null) {
      widget.controller.endObjectTransform();
    }
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    if (!widget.interactionEnabled) {
      return;
    }
    if (_pointer != null) {
      _onCancel();
      return;
    }
    final handles = ShapeEditGeometry.handles(_displayStroke);
    var handleIndex = -1;
    for (var i = 0; i < handles.length; i++) {
      if ((handles[i] - event.localPosition).distance <= 14) {
        handleIndex = i;
        break;
      }
    }
    if (handleIndex < 0 &&
        !ShapeEditGeometry.hitTest(_displayStroke, event.localPosition)) {
      return;
    }
    _pointer = event.pointer;
    _handle = handleIndex;
    _start = event.localPosition;
    _before = widget.stroke;
    widget.controller.beginObjectTransform();
  }

  void _onMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _before == null || _start == null) {
      return;
    }
    final delta = event.localPosition - _start!;
    final next = _handle == -1
        ? ShapeEditGeometry.moved(_before!, delta)
        : ShapeEditGeometry.resized(_before!, _handle!, delta);
    widget.controller.previewShapeStrokeOnPage(widget.pageIndex, next);
  }

  void _onUp(PointerUpEvent event) {
    if (_pointer != event.pointer) {
      return;
    }
    final before = _before;
    _clear();
    if (before == null) {
      return;
    }
    final after = widget.controller.shapeStrokeOnPage(
      widget.pageIndex,
      before.id,
    );
    if (after != null) {
      widget.controller.commitShapeStrokeOnPage(
        widget.pageIndex,
        before,
        after,
      );
    }
  }

  void _onCancel() {
    final before = _before;
    _clear();
    if (before != null) {
      widget.controller.previewShapeStrokeOnPage(widget.pageIndex, before);
    }
  }

  void _clear() {
    if (_pointer != null) {
      widget.controller.endObjectTransform();
    }
    _pointer = null;
    _handle = null;
    _start = null;
    _before = null;
  }

  @override
  Widget build(BuildContext context) {
    final stroke = _displayStroke;
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: (_) => _onCancel(),
      child: CustomPaint(
        size: Size.infinite,
        painter: _ShapeHandlesPainter(
          stroke: stroke,
          color: Theme.of(context).colorScheme.onSurface,
          interactive: widget.interactionEnabled,
        ),
      ),
    );
  }
}

class _ShapeHandlesPainter extends CustomPainter {
  const _ShapeHandlesPainter({
    required this.stroke,
    required this.color,
    required this.interactive,
  });

  final InkStroke stroke;
  final Color color;
  final bool interactive;

  @override
  void paint(Canvas canvas, Size size) {
    final points = stroke.points.map((point) => point.toOffset()).toList();
    if (points.isEmpty) {
      return;
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    for (final point in ShapeEditGeometry.handles(stroke)) {
      canvas.drawCircle(
        point,
        5.5,
        Paint()..color = const Color(0xFFFAFAFA),
      );
      canvas.drawCircle(
        point,
        5.5,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool? hitTest(Offset position) =>
      interactive && ShapeEditGeometry.hitTest(stroke, position, radius: 14);

  @override
  bool shouldRepaint(covariant _ShapeHandlesPainter oldDelegate) =>
      oldDelegate.stroke != stroke ||
      oldDelegate.color != color ||
      oldDelegate.interactive != interactive;
}
