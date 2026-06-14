import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/input/stylus_button_state.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/ink_stroke.dart';
import '../../../notebook/domain/note_page.dart';
import '../../state/editor_controller.dart';

const double _eraserBrushWidthScale = 2.0;
const double _eraserStrokeMinRadius = 4.0;
const double _eraserStrokeRadiusScale = 1.5;
const double _eraserTrailMaxLength = 96.0;
const double _scratchEraseRadiusScale = 4.0;
const int _scratchEraseMinDirectionReversals = 3;
const Color _canvasBackgroundColor = AppColors.paper;

class _PartialEraseResult {
  const _PartialEraseResult({required this.strokes, required this.changed});

  final List<InkStroke> strokes;
  final bool changed;
}

_PartialEraseResult _eraseStrokeParts({
  required List<InkStroke> strokes,
  required List<InkPoint> gesture,
  required double radius,
  required String Function() createId,
}) {
  final gestureOffsets = gesture.map((point) => point.toOffset()).toList();
  final next = <InkStroke>[];
  var changed = false;
  for (final stroke in strokes) {
    if (!_canScratchEraseStroke(stroke) || stroke.points.length < 2) {
      next.add(stroke);
      continue;
    }
    final parts = _splitStrokeAroundGesture(
      stroke,
      gestureOffsets,
      radius,
      createId,
    );
    if (parts == null) {
      next.add(stroke);
      continue;
    }
    changed = true;
    next.addAll(parts);
  }
  return _PartialEraseResult(strokes: next, changed: changed);
}

List<InkStroke>? _splitStrokeAroundGesture(
  InkStroke stroke,
  List<Offset> gesture,
  double radius,
  String Function() createId,
) {
  final points = stroke.points;
  final removed = List<bool>.filled(points.length, false);
  for (var i = 0; i < points.length; i++) {
    if (_distanceSquaredToPolyline(points[i].toOffset(), gesture) <=
        radius * radius) {
      removed[i] = true;
    }
  }
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i].toOffset();
    final b = points[i + 1].toOffset();
    if (_segmentDistanceSquaredToPolyline(a, b, gesture) <= radius * radius) {
      removed[i] = true;
      removed[i + 1] = true;
    }
  }
  if (!removed.contains(true)) {
    return null;
  }

  final parts = <InkStroke>[];
  var run = <InkPoint>[];
  void flushRun() {
    if (run.length >= 2) {
      parts.add(stroke.copyWith(id: createId(), points: List.of(run)));
    }
    run = <InkPoint>[];
  }

  for (var i = 0; i < points.length; i++) {
    if (removed[i]) {
      flushRun();
    } else {
      run.add(points[i]);
    }
  }
  flushRun();
  return parts;
}

bool _canScratchEraseStroke(InkStroke stroke) {
  return stroke.tool != DrawingTool.eraserBrush &&
      stroke.tool != DrawingTool.eraserStroke &&
      stroke.tool != DrawingTool.eraserArea &&
      stroke.tool != DrawingTool.lasso;
}

bool _isScratchEraseGesture(
  List<InkPoint> points,
  PointerDeviceKind pointerKind,
) {
  if (pointerKind != PointerDeviceKind.stylus &&
      pointerKind != PointerDeviceKind.invertedStylus &&
      pointerKind != PointerDeviceKind.mouse) {
    return false;
  }
  return _directionReversalCount(points) >= _scratchEraseMinDirectionReversals;
}

int _directionReversalCount(List<InkPoint> points) {
  var reversals = 0;
  Offset? previousDirection;
  for (var i = 1; i < points.length; i++) {
    final delta = points[i].toOffset() - points[i - 1].toOffset();
    if (delta.distanceSquared < 4.0) {
      continue;
    }
    final direction = delta / delta.distance;
    final previous = previousDirection;
    if (previous != null) {
      final dot = previous.dx * direction.dx + previous.dy * direction.dy;
      if (dot < -0.25) {
        reversals++;
      }
    }
    previousDirection = direction;
  }
  return reversals;
}

double _distanceSquaredToPolyline(Offset point, List<Offset> polyline) {
  if (polyline.isEmpty) {
    return double.infinity;
  }
  if (polyline.length == 1) {
    return (point - polyline.first).distanceSquared;
  }
  var best = double.infinity;
  for (var i = 0; i < polyline.length - 1; i++) {
    best = min(
      best,
      _distanceSquaredToSegment(point, polyline[i], polyline[i + 1]),
    );
  }
  return best;
}

double _segmentDistanceSquaredToPolyline(
  Offset a,
  Offset b,
  List<Offset> polyline,
) {
  if (polyline.length < 2) {
    return min(
      (a - polyline.first).distanceSquared,
      (b - polyline.first).distanceSquared,
    );
  }
  var best = double.infinity;
  for (var i = 0; i < polyline.length - 1; i++) {
    best = min(
      best,
      _distanceSquaredBetweenSegments(a, b, polyline[i], polyline[i + 1]),
    );
  }
  return best;
}

double _distanceSquaredBetweenSegments(Offset a, Offset b, Offset c, Offset d) {
  if (_segmentsIntersect(a, b, c, d)) {
    return 0;
  }
  return min(
    min(_distanceSquaredToSegment(a, c, d), _distanceSquaredToSegment(b, c, d)),
    min(_distanceSquaredToSegment(c, a, b), _distanceSquaredToSegment(d, a, b)),
  );
}

bool _segmentsIntersect(Offset a, Offset b, Offset c, Offset d) {
  final abC = _cross(b - a, c - a);
  final abD = _cross(b - a, d - a);
  final cdA = _cross(d - c, a - c);
  final cdB = _cross(d - c, b - c);
  return abC.sign != abD.sign && cdA.sign != cdB.sign;
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;

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

class DrawingCanvas extends StatefulWidget {
  const DrawingCanvas({
    this.allowMultiTouch = true,
    this.interactionEnabled = true,
    this.worldOrigin = Offset.zero,
    this.page,
    this.pageIndex,
    super.key,
  });

  final bool allowMultiTouch;
  final bool interactionEnabled;
  final Offset worldOrigin;
  final NotePage? page;
  final int? pageIndex;

  @override
  State<DrawingCanvas> createState() => _DrawingCanvasState();
}

class DocumentDrawingCanvas extends StatefulWidget {
  const DocumentDrawingCanvas({
    required this.pages,
    required this.pageSize,
    required this.pageGap,
    this.allowMultiTouch = true,
    this.interactionEnabled = true,
    this.worldOrigin = Offset.zero,
    this.firstPageIndex = 0,
    this.lastPageIndex,
    super.key,
  });

  final List<NotePage> pages;
  final Size pageSize;
  final double pageGap;
  final bool allowMultiTouch;
  final bool interactionEnabled;
  final Offset worldOrigin;
  final int firstPageIndex;
  final int? lastPageIndex;

  @override
  State<DocumentDrawingCanvas> createState() => _DocumentDrawingCanvasState();
}

Path _buildInkPath(
  List<InkPoint> points,
  DrawingTool tool,
  Offset origin,
  Offset worldOrigin,
  Offset delta,
) {
  final offsets = points
      .map((point) => point.toOffset() + origin + delta - worldOrigin)
      .toList();
  final path = Path();
  if (offsets.isEmpty) {
    return path;
  }
  path.moveTo(offsets.first.dx, offsets.first.dy);
  if (!_shouldSmoothStroke(points, tool)) {
    for (var i = 1; i < offsets.length; i++) {
      path.lineTo(offsets[i].dx, offsets[i].dy);
    }
  } else {
    for (var i = 1; i < offsets.length - 1; i++) {
      final current = offsets[i];
      final next = offsets[i + 1];
      final midpoint = Offset(
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );
      path.quadraticBezierTo(current.dx, current.dy, midpoint.dx, midpoint.dy);
    }
    path.lineTo(offsets.last.dx, offsets.last.dy);
  }
  if (_samePoint(points.first, points.last)) {
    path.close();
  }
  return path;
}

bool _shouldSmoothStroke(List<InkPoint> points, DrawingTool tool) {
  if (tool != DrawingTool.pen && tool != DrawingTool.highlighter) {
    return false;
  }
  if (points.length < 4 || _samePoint(points.first, points.last)) {
    return false;
  }
  var longestSegmentSquared = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    final distanceSquared =
        (points[i + 1].toOffset() - points[i].toOffset()).distanceSquared;
    longestSegmentSquared = max(longestSegmentSquared, distanceSquared);
  }
  return longestSegmentSquared > 64.0;
}

bool _samePoint(InkPoint a, InkPoint b) {
  return a.dx == b.dx && a.dy == b.dy;
}

List<InkPoint> _closedAreaPoints(List<InkPoint> points) {
  if (points.length < 3 || _samePoint(points.first, points.last)) {
    return List<InkPoint>.from(points);
  }
  return <InkPoint>[
    ...points,
    InkPoint(
      dx: points.first.dx,
      dy: points.first.dy,
      pressure: points.first.pressure,
    ),
  ];
}

bool _shouldAcceptInkPoint(
  List<InkPoint> points,
  Offset offset,
  DrawingTool tool,
) {
  if (points.isEmpty) {
    return true;
  }
  final last = points.last.toOffset();
  if ((offset - last).distanceSquared <= 0.5) {
    return false;
  }
  if (tool != DrawingTool.pen && tool != DrawingTool.highlighter) {
    return true;
  }
  return !_isDiscontinuousInkJump(points, offset);
}

bool _shouldRejectViewportEdgePoint(
  List<InkPoint> points,
  Offset offset,
  Offset localPosition,
  Size viewportSize,
  DrawingTool tool,
) {
  if (tool != DrawingTool.pen && tool != DrawingTool.highlighter) {
    return false;
  }
  if (points.isEmpty || !_isNearViewportEdge(localPosition, viewportSize)) {
    return false;
  }
  final last = points.last.toOffset();
  final jumpLength = (offset - last).distance;
  return jumpLength > 28.0 && _isDiscontinuousInkJump(points, offset);
}

bool _isNearViewportEdge(Offset localPosition, Size viewportSize) {
  const edgeSlop = 2.0;
  if (viewportSize.width <= 0 || viewportSize.height <= 0) {
    return false;
  }
  return localPosition.dx <= edgeSlop ||
      localPosition.dy <= edgeSlop ||
      localPosition.dx >= viewportSize.width - edgeSlop ||
      localPosition.dy >= viewportSize.height - edgeSlop;
}

bool _isDiscontinuousInkJump(List<InkPoint> points, Offset offset) {
  final last = points.last.toOffset();
  Offset? previous;
  for (var i = points.length - 2; i >= 0; i--) {
    final candidate = points[i].toOffset();
    if ((last - candidate).distanceSquared > 16.0) {
      previous = candidate;
      break;
    }
  }
  if (previous == null) {
    return false;
  }

  final recent = last - previous;
  final jump = offset - last;
  final recentLength = recent.distance;
  final jumpLength = jump.distance;
  final maxExpectedJump = max(96.0, recentLength * 3.2);
  if (jumpLength <= maxExpectedJump) {
    return false;
  }

  final perpendicular =
      (recent.dx * jump.dy - recent.dy * jump.dx).abs() / recentLength;
  final maxExpectedDrift = max(42.0, recentLength * 1.4);
  return perpendicular > maxExpectedDrift;
}

DrawingTool _toolForPointerEvent(
  PointerEvent event,
  DrawingTool currentTool,
  DrawingTool eraserTool,
) {
  if (event.kind == PointerDeviceKind.invertedStylus ||
      StylusButtonState.isPressed ||
      _hasStylusButton(event)) {
    return eraserTool;
  }
  return currentTool;
}

void _toggleEraserShortcut(EditorController controller) {
  controller.setTool(
    controller.tool.isEraser ? DrawingTool.pen : controller.lastEraserTool,
  );
}

bool _hasStylusButton(PointerEvent event) {
  if (event.kind == PointerDeviceKind.stylus ||
      event.kind == PointerDeviceKind.invertedStylus) {
    const stylusButtons = kPrimaryStylusButton | kSecondaryStylusButton;
    return event.buttons & stylusButtons != 0;
  }
  if (defaultTargetPlatform == TargetPlatform.linux &&
      event.kind == PointerDeviceKind.mouse) {
    const stylusButtonFallback = kSecondaryMouseButton | kMiddleMouseButton;
    return event.buttons & stylusButtonFallback != 0;
  }
  return false;
}

double _eraserStrokeRadius(double strokeWidth) {
  return max(_eraserStrokeMinRadius, strokeWidth * _eraserStrokeRadiusScale);
}

void _trimEraserTrail(List<Offset> trail) {
  var length = 0.0;
  for (var i = trail.length - 1; i > 0; i--) {
    length += (trail[i] - trail[i - 1]).distance;
    if (length > _eraserTrailMaxLength) {
      trail.removeRange(0, i);
      return;
    }
  }
}

class _DrawingCanvasState extends State<DrawingCanvas> {
  static const double _touchStrokeStartSlop = 6.0;
  static const double _palmContactRadius = 22.0;

  final List<InkPoint> _currentPoints = <InkPoint>[];
  final List<Offset> _eraserTrail = <Offset>[];
  final ValueNotifier<int> _inkRepaint = ValueNotifier<int>(0);
  final Set<String> _eraseStrokeIds = <String>{};
  final Set<int> _activePointers = <int>{};
  int? _primaryPointer;
  PointerDeviceKind? _primaryPointerKind;
  DrawingTool? _activeToolOverride;
  Offset? _pendingTouchStart;
  bool _activePointerAllowsTapStroke = false;
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
  bool _suspendInk = false;

  @override
  void initState() {
    super.initState();
    StylusButtonState.eraserToggleRequests.addListener(
      _handleEraserToggleRequest,
    );
  }

  @override
  void dispose() {
    StylusButtonState.eraserToggleRequests.removeListener(
      _handleEraserToggleRequest,
    );
    _inkRepaint.dispose();
    super.dispose();
  }

  void _handleEraserToggleRequest() {
    if (!mounted) {
      return;
    }
    _resetCurrent();
    _toggleEraserShortcut(context.read<EditorController>());
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final page = _resolvedPage(controller);
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
        final activeTool = _activeTool(controller);
        final lassoSelection =
            controller.lassoSelection?.pageIndex ==
                _resolvedPageIndex(controller)
            ? controller.lassoSelection
            : null;
        final currentWidth = _effectiveStrokeWidth(
          activeTool,
          controller.inkStrokeWidth,
        );
        final eraserRadius = activeTool == DrawingTool.eraserBrush
            ? currentWidth / 2
            : _eraserStrokeRadius(controller.inkStrokeWidth);
        return IgnorePointer(
          ignoring: !isInkTool || !widget.interactionEnabled || _suspendInk,
          child: MouseRegion(
            cursor: _usesCustomInkCursor(controller.tool)
                ? SystemMouseCursors.basic
                : MouseCursor.defer,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) =>
                  _onPointerDown(event, controller, constraints.biggest),
              onPointerMove: (event) =>
                  _onPointerMove(event, controller, constraints.biggest),
              onPointerUp: (event) => _onPointerUp(event, controller),
              onPointerCancel: (event) => _onPointerCancel(event),
              child: ValueListenableBuilder<Offset>(
                valueListenable: controller.lassoDragDelta,
                builder: (context, lassoDelta, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _InkPainter(
                          strokes: page.inkStrokes,
                          worldOrigin: widget.worldOrigin,
                          selectedStrokeIds:
                              lassoSelection?.strokeIds.toSet() ?? {},
                          selectionDelta: lassoSelection == null
                              ? Offset.zero
                              : lassoDelta,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _InkOverlayPainter(
                          repaint: _inkRepaint,
                          currentPoints: _currentPoints,
                          currentColor: controller.inkColor,
                          currentWidth: currentWidth,
                          currentTool: activeTool,
                          worldOrigin: widget.worldOrigin,
                          snapHintStart: _snapHintStart,
                          snapHintEnd: _snapHintEnd,
                          eraserPosition: _eraserPosition,
                          eraserRadius: eraserRadius,
                          eraserTrail: _eraserTrail,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _onPointerDown(
    PointerDownEvent event,
    EditorController controller,
    Size viewportSize,
  ) {
    if (_primaryPointer != null) {
      if (!_shouldDelayTouchStroke(_primaryPointerKind!)) {
        return;
      }
      _activePointers.add(event.pointer);
      if (_activePointers.length > 1) {
        _suspendInk = true;
        _resetCurrent();
      }
      return;
    }
    if (_isPalmLikeTouch(event)) {
      return;
    }
    if ((controller.tool == DrawingTool.pen ||
            controller.tool == DrawingTool.highlighter) &&
        _isNearViewportEdge(event.localPosition, viewportSize)) {
      return;
    }
    final inputTool = _toolForPointerEvent(
      event,
      controller.tool,
      controller.lastEraserTool,
    );
    final page = _resolvedPage(controller);
    _activePointers.add(event.pointer);
    if (_activePointers.length > 1) {
      _suspendInk = true;
      _resetCurrent();
      return;
    }
    if (!_isInkTool(inputTool)) {
      return;
    }
    final offset = _toWorld(event.localPosition);
    _primaryPointer = event.pointer;
    _primaryPointerKind = event.kind;
    _activeToolOverride = inputTool == controller.tool ? null : inputTool;
    _activePointerAllowsTapStroke = _canCommitTapStroke(event.kind);
    if (_shouldDelayTouchStroke(event.kind)) {
      _pendingTouchStart = offset;
      return;
    }
    _beginStrokeAt(offset, controller, page, inputTool, event.pressure);
  }

  void _beginStrokeAt(
    Offset offset,
    EditorController controller,
    NotePage page,
    DrawingTool tool,
    double pressure,
  ) {
    if (tool.isShape) {
      _shapeStart = offset;
      _currentPoints
        ..clear()
        ..addAll(_buildShapePoints(tool, offset, offset));
      _notifyInkChanged();
      return;
    }
    if (tool == DrawingTool.eraserStroke) {
      _eraseStrokeIds.clear();
      _eraserPosition = offset;
      _eraserTrail
        ..clear()
        ..add(offset);
      _eraseAt(offset, page, controller);
      _notifyInkChanged();
      return;
    }
    if (tool == DrawingTool.eraserArea) {
      _currentPoints
        ..clear()
        ..add(InkPoint.fromOffset(offset, pressure));
      _notifyInkChanged();
      return;
    }
    if (tool == DrawingTool.eraserBrush) {
      _eraserPosition = offset;
    }
    _currentPoints
      ..clear()
      ..add(InkPoint.fromOffset(offset, pressure));
    _snappedStraight = false;
    _snappedRect = false;
    _snappedEllipse = false;
    _rectFixedCorner = null;
    _ellipseFixedCorner = null;
    _notifyInkChanged();
    if (_isSnapTool(tool)) {
      _startSnapTimer(offset);
    }
  }

  void _onPointerMove(
    PointerMoveEvent event,
    EditorController controller,
    Size viewportSize,
  ) {
    final page = _resolvedPage(controller);
    if (event.pointer != _primaryPointer) {
      return;
    }
    if (_suspendInk || _activePointers.length > 1) {
      return;
    }
    var tool = _activeTool(controller);
    final offset = _toWorld(event.localPosition);
    if (_shouldRejectViewportEdgePoint(
      _currentPoints,
      offset,
      event.localPosition,
      viewportSize,
      tool,
    )) {
      return;
    }
    final pendingStart = _pendingTouchStart;
    if (pendingStart != null) {
      if ((offset - pendingStart).distance < _touchStrokeStartSlop) {
        return;
      }
      _pendingTouchStart = null;
      _beginStrokeAt(pendingStart, controller, page, tool, event.pressure);
    }
    tool = _syncActiveToolWithPointerMove(
      event,
      controller,
      page,
      offset,
      tool,
    );
    if (tool == DrawingTool.eraserStroke) {
      _eraserPosition = offset;
      _addEraserTrailPoint(offset);
      _eraseAt(offset, page, controller);
      _notifyInkChanged();
      return;
    }
    if (tool == DrawingTool.eraserArea) {
      if (_shouldAddPoint(offset, tool)) {
        _currentPoints.add(InkPoint.fromOffset(offset, event.pressure));
        _notifyInkChanged();
      }
      return;
    }
    if (tool.isShape) {
      if (_shapeStart == null) {
        return;
      }
      _currentPoints
        ..clear()
        ..addAll(_buildShapePoints(tool, _shapeStart!, offset));
      _notifyInkChanged();
      return;
    }
    if (_currentPoints.isEmpty) {
      return;
    }
    if (_isSnapTool(tool)) {
      _startSnapTimer(offset);
    }
    if (tool == DrawingTool.eraserBrush) {
      _eraserPosition = offset;
      _notifyInkChanged();
    }
    if (_snappedStraight) {
      if (_currentPoints.length >= 2) {
        _currentPoints[_currentPoints.length - 1] = InkPoint.fromOffset(
          offset,
          event.pressure,
        );
        _notifyInkChanged();
      }
      return;
    }
    if (_snappedRect) {
      if (_currentPoints.length == 5) {
        // Update rectangle using fixed far corner and moving hold point
        final fixed = _rectFixedCorner ?? _currentPoints.first.toOffset();
        final points = _buildRectanglePoints(fixed, offset, event.pressure);
        _currentPoints
          ..clear()
          ..addAll(points);
        _notifyInkChanged();
      }
      return;
    }
    if (_snappedEllipse) {
      final fixed = _ellipseFixedCorner ?? _currentPoints.first.toOffset();
      _currentPoints
        ..clear()
        ..addAll(_buildEllipsePoints(fixed, offset, event.pressure));
      _notifyInkChanged();
      return;
    }
    if (!_shouldAddPoint(offset, tool)) {
      return;
    }
    _currentPoints.add(InkPoint.fromOffset(offset, event.pressure));
    _notifyInkChanged();
  }

  void _onPointerUp(PointerUpEvent event, EditorController controller) {
    final pageIndex = _resolvedPageIndex(controller);
    _activePointers.remove(event.pointer);
    if (event.pointer != _primaryPointer) {
      if (_primaryPointer == null && _activePointers.length <= 1) {
        _suspendInk = false;
      }
      return;
    }
    if (_activePointers.length > 1) {
      _resetCurrent();
      return;
    }
    if (_suspendInk && _activePointers.length <= 1) {
      _suspendInk = false;
    }
    if (_pendingTouchStart != null) {
      _resetCurrent();
      return;
    }
    var tool = _activeTool(controller);
    if (tool.isShape) {
      if (_currentPoints.isEmpty) {
        _resetCurrent();
        return;
      }
      if (widget.pageIndex != null) {
        controller.addInkStrokeOnPage(
          pageIndex,
          List<InkPoint>.from(_currentPoints),
          widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
          toolOverride: tool,
        );
      } else {
        controller.addInkStroke(
          List<InkPoint>.from(_currentPoints),
          widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
          toolOverride: tool,
        );
      }
      _resetCurrent();
      return;
    }
    if (tool == DrawingTool.eraserStroke) {
      if (_eraseStrokeIds.isNotEmpty) {
        if (widget.pageIndex != null) {
          controller.eraseInkStrokesByIdOnPage(pageIndex, _eraseStrokeIds);
        } else {
          controller.eraseInkStrokesById(_eraseStrokeIds);
        }
        _eraseStrokeIds.clear();
      }
      _eraserPosition = null;
      _resetCurrent();
      return;
    }
    if (tool == DrawingTool.eraserArea) {
      if (_currentPoints.length >= 3) {
        final points = _closedAreaPoints(_currentPoints);
        if (widget.pageIndex != null) {
          controller.addInkStrokeOnPage(
            pageIndex,
            points,
            widthOverride: _effectiveStrokeWidth(
              tool,
              controller.inkStrokeWidth,
            ),
            toolOverride: tool,
          );
        } else {
          controller.addInkStroke(
            points,
            widthOverride: _effectiveStrokeWidth(
              tool,
              controller.inkStrokeWidth,
            ),
            toolOverride: tool,
          );
        }
      }
      _resetCurrent();
      return;
    }
    if (_currentPoints.isEmpty) {
      return;
    }
    _snapTimer?.cancel();
    if (_currentPoints.length == 1) {
      if (!_activePointerAllowsTapStroke) {
        _resetCurrent();
        return;
      }
      final point = _currentPoints.first;
      _currentPoints.add(
        InkPoint(dx: point.dx + 0.5, dy: point.dy, pressure: point.pressure),
      );
    }
    if (_tryCommitScratchErase(controller, pageIndex, tool)) {
      _resetCurrent();
      return;
    }
    if (widget.pageIndex != null) {
      if (tool == DrawingTool.lasso) {
        controller.selectWithLasso(
          _currentPoints.map((p) => p.toOffset()).toList(),
          pageIndex,
        );
      } else {
        controller.addInkStrokeOnPage(
          pageIndex,
          List<InkPoint>.from(_currentPoints),
          widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
          toolOverride: tool,
        );
      }
    } else {
      if (tool == DrawingTool.lasso) {
        controller.selectWithLasso(
          _currentPoints.map((p) => p.toOffset()).toList(),
          pageIndex,
        );
      } else {
        controller.addInkStroke(
          List<InkPoint>.from(_currentPoints),
          widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
          toolOverride: tool,
        );
      }
    }
    _resetCurrent();
  }

  DrawingTool _syncActiveToolWithPointerMove(
    PointerMoveEvent event,
    EditorController controller,
    NotePage page,
    Offset offset,
    DrawingTool currentTool,
  ) {
    final targetTool = _toolForPointerEvent(
      event,
      controller.tool,
      controller.lastEraserTool,
    );
    if (targetTool == currentTool) {
      return currentTool;
    }
    _commitCurrentSegment(
      controller,
      _resolvedPageIndex(controller),
      currentTool,
      allowTapStroke: false,
    );
    _clearCurrentSegmentForToolSwitch();
    _activeToolOverride = targetTool == controller.tool ? null : targetTool;
    _primaryPointer = event.pointer;
    _primaryPointerKind = event.kind;
    _activePointerAllowsTapStroke = _canCommitTapStroke(event.kind);
    _beginStrokeAt(offset, controller, page, targetTool, event.pressure);
    return targetTool;
  }

  void _commitCurrentSegment(
    EditorController controller,
    int pageIndex,
    DrawingTool tool, {
    required bool allowTapStroke,
  }) {
    _snapTimer?.cancel();
    if (tool.isShape) {
      if (_currentPoints.isNotEmpty) {
        _addCurrentStroke(controller, pageIndex, tool);
      }
      return;
    }
    if (tool == DrawingTool.eraserStroke) {
      if (_eraseStrokeIds.isNotEmpty) {
        if (widget.pageIndex != null) {
          controller.eraseInkStrokesByIdOnPage(pageIndex, _eraseStrokeIds);
        } else {
          controller.eraseInkStrokesById(_eraseStrokeIds);
        }
      }
      return;
    }
    if (tool == DrawingTool.eraserArea) {
      if (_currentPoints.length >= 3) {
        final points = _closedAreaPoints(_currentPoints);
        if (widget.pageIndex != null) {
          controller.addInkStrokeOnPage(
            pageIndex,
            points,
            widthOverride: _effectiveStrokeWidth(
              tool,
              controller.inkStrokeWidth,
            ),
            toolOverride: tool,
          );
        } else {
          controller.addInkStroke(
            points,
            widthOverride: _effectiveStrokeWidth(
              tool,
              controller.inkStrokeWidth,
            ),
            toolOverride: tool,
          );
        }
      }
      return;
    }
    if (_currentPoints.isEmpty) {
      return;
    }
    if (_currentPoints.length == 1) {
      if (!allowTapStroke || !_activePointerAllowsTapStroke) {
        return;
      }
      final point = _currentPoints.first;
      _currentPoints.add(
        InkPoint(dx: point.dx + 0.5, dy: point.dy, pressure: point.pressure),
      );
    }
    if (_tryCommitScratchErase(controller, pageIndex, tool)) {
      return;
    }
    if (tool == DrawingTool.lasso) {
      controller.selectWithLasso(
        _currentPoints.map((p) => p.toOffset()).toList(),
        pageIndex,
      );
      return;
    }
    _addCurrentStroke(controller, pageIndex, tool);
  }

  void _addCurrentStroke(
    EditorController controller,
    int pageIndex,
    DrawingTool tool,
  ) {
    if (widget.pageIndex != null) {
      controller.addInkStrokeOnPage(
        pageIndex,
        List<InkPoint>.from(_currentPoints),
        widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
        toolOverride: tool,
      );
    } else {
      controller.addInkStroke(
        List<InkPoint>.from(_currentPoints),
        widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
        toolOverride: tool,
      );
    }
  }

  bool _tryCommitScratchErase(
    EditorController controller,
    int pageIndex,
    DrawingTool tool,
  ) {
    final pointerKind = _primaryPointerKind;
    if (tool != DrawingTool.pen || pointerKind == null) {
      return false;
    }
    final result = _eraseStrokeParts(
      strokes: _resolvedPage(controller).inkStrokes,
      gesture: _currentPoints,
      radius: max(8.0, controller.inkStrokeWidth * _scratchEraseRadiusScale),
      createId: controller.createInkStrokeId,
    );
    if (!result.changed) {
      return false;
    }
    if (!_isScratchEraseGesture(_currentPoints, pointerKind)) {
      return false;
    }
    if (widget.pageIndex != null) {
      controller.replaceInkStrokesOnPage(pageIndex, result.strokes);
    } else {
      controller.replaceInkStrokes(result.strokes);
    }
    return true;
  }

  void _clearCurrentSegmentForToolSwitch() {
    _snapTimer?.cancel();
    _snapHintTimer?.cancel();
    _eraseStrokeIds.clear();
    _eraserPosition = null;
    _eraserTrail.clear();
    _snappedStraight = false;
    _snappedRect = false;
    _snappedEllipse = false;
    _snapHintStart = null;
    _snapHintEnd = null;
    _snapAnchor = null;
    _rectFixedCorner = null;
    _ellipseFixedCorner = null;
    _shapeStart = null;
    _pendingTouchStart = null;
    _currentPoints.clear();
    _notifyInkChanged();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer != _primaryPointer) {
      if (_primaryPointer == null && _activePointers.length <= 1) {
        _suspendInk = false;
      }
      return;
    }
    if (_activePointers.length <= 1) {
      _suspendInk = false;
    }
    _resetCurrent();
  }

  void _resetCurrent() {
    _snapTimer?.cancel();
    _snapHintTimer?.cancel();
    _eraseStrokeIds.clear();
    _eraserPosition = null;
    _eraserTrail.clear();
    _snappedStraight = false;
    _snappedRect = false;
    _snappedEllipse = false;
    _snapHintStart = null;
    _snapHintEnd = null;
    _snapAnchor = null;
    _rectFixedCorner = null;
    _ellipseFixedCorner = null;
    _shapeStart = null;
    _primaryPointer = null;
    _primaryPointerKind = null;
    _activeToolOverride = null;
    _pendingTouchStart = null;
    _activePointerAllowsTapStroke = false;
    if (_currentPoints.isEmpty) {
      _notifyInkChanged();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _currentPoints.clear();
    _notifyInkChanged();
    if (mounted) {
      setState(() {});
    }
  }

  void _notifyInkChanged() {
    _inkRepaint.value++;
  }

  void _addEraserTrailPoint(Offset offset) {
    if (_eraserTrail.isEmpty ||
        (offset - _eraserTrail.last).distanceSquared >= 4.0) {
      _eraserTrail.add(offset);
      _trimEraserTrail(_eraserTrail);
    }
  }

  DrawingTool _activeTool(EditorController controller) {
    return _activeToolOverride ?? controller.tool;
  }

  Offset _toWorld(Offset localPosition) {
    return localPosition + widget.worldOrigin;
  }

  bool _shouldAddPoint(Offset offset, DrawingTool tool) {
    return _shouldAcceptInkPoint(_currentPoints, offset, tool);
  }

  bool _shouldDelayTouchStroke(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch;
  }

  bool _canCommitTapStroke(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus ||
        kind == PointerDeviceKind.mouse;
  }

  bool _isPalmLikeTouch(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return false;
    }
    return max(event.radiusMajor, event.radiusMinor) >= _palmContactRadius;
  }

  void _startSnapTimer(Offset offset) {
    const jitterTolerance = 20.0;
    if (_snapAnchor == null ||
        (offset - _snapAnchor!).distance > jitterTolerance) {
      _snapAnchor = offset;
      _snapTimer?.cancel();
      _snapTimer = Timer(const Duration(milliseconds: 1200), _snapToShape);
    }
  }

  void _eraseAt(Offset offset, NotePage page, EditorController controller) {
    final radius = _eraserStrokeRadius(controller.inkStrokeWidth);
    for (final stroke in page.inkStrokes) {
      if (_eraseStrokeIds.contains(stroke.id)) {
        continue;
      }
      if (_strokeHitTest(stroke, offset, radius)) {
        _eraseStrokeIds.add(stroke.id);
      }
    }
  }

  NotePage _resolvedPage(EditorController controller) {
    return widget.page ?? controller.currentPage;
  }

  int _resolvedPageIndex(EditorController controller) {
    return widget.pageIndex ?? controller.currentPageIndex;
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
    if (_currentPoints.length < 2 ||
        _snappedStraight ||
        _snappedRect ||
        _snappedEllipse) {
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

  bool _isRoughlyStraight(Offset start, Offset end, List<InkPoint> points) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = sqrt(dx * dx + dy * dy);
    if (length < 2) {
      return false;
    }
    final maxDistance = max(8.0, length * 0.08);
    for (final point in points) {
      final offset = point.toOffset();
      final distance =
          ((dy * offset.dx -
                  dx * offset.dy +
                  end.dx * start.dy -
                  end.dy * start.dx)
              .abs()) /
          length;
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

  bool _usesCustomInkCursor(DrawingTool tool) {
    return tool == DrawingTool.pen || tool == DrawingTool.highlighter;
  }

  double _effectiveStrokeWidth(DrawingTool tool, double baseWidth) {
    if (tool == DrawingTool.highlighter) {
      return baseWidth * 8.0;
    }
    if (tool == DrawingTool.eraserBrush) {
      return baseWidth * _eraserBrushWidthScale;
    }
    if (tool == DrawingTool.eraserArea) {
      return max(1.5, baseWidth * 0.5);
    }
    return baseWidth;
  }

  List<InkPoint> _buildShapePoints(DrawingTool tool, Offset start, Offset end) {
    switch (tool) {
      case DrawingTool.line:
        return [InkPoint.fromOffset(start, 1.0), InkPoint.fromOffset(end, 1.0)];
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
        return [InkPoint.fromOffset(start, 1.0), InkPoint.fromOffset(end, 1.0)];
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
      return [InkPoint.fromOffset(start, 1.0), InkPoint.fromOffset(end, 1.0)];
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
      return _buildRectanglePoints(
        Offset(left, top),
        Offset(right, bottom),
        1.0,
      );
    }

    final minBodyWidth = max(6.0, width * 0.15);
    var headWidth = max(12.0, width * 0.35);
    if (headWidth > width - minBodyWidth) {
      headWidth = width - minBodyWidth;
    }
    if (headWidth <= 0) {
      return _buildRectanglePoints(
        Offset(left, top),
        Offset(right, bottom),
        1.0,
      );
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

class _DocumentDrawingCanvasState extends State<DocumentDrawingCanvas> {
  static const double _touchStrokeStartSlop = 6.0;
  static const double _palmContactRadius = 22.0;

  final List<InkPoint> _currentPoints = <InkPoint>[];
  final List<Offset> _eraserTrail = <Offset>[];
  final ValueNotifier<int> _inkRepaint = ValueNotifier<int>(0);
  final Set<String> _eraseStrokeIds = <String>{};
  final Set<int> _activePointers = <int>{};
  int? _primaryPointer;
  PointerDeviceKind? _primaryPointerKind;
  DrawingTool? _activeToolOverride;
  Offset? _pendingTouchStart;
  int? _pendingTouchPageIndex;
  bool _activePointerAllowsTapStroke = false;
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
  int? _activePageIndex;
  bool _suspendInk = false;

  @override
  void initState() {
    super.initState();
    StylusButtonState.eraserToggleRequests.addListener(
      _handleEraserToggleRequest,
    );
  }

  @override
  void dispose() {
    StylusButtonState.eraserToggleRequests.removeListener(
      _handleEraserToggleRequest,
    );
    _inkRepaint.dispose();
    super.dispose();
  }

  void _handleEraserToggleRequest() {
    if (!mounted) {
      return;
    }
    _resetCurrent();
    _toggleEraserShortcut(context.read<EditorController>());
  }

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
        final activeTool = _activeTool(controller);
        final lassoSelection = controller.lassoSelection;
        final currentWidth = _effectiveStrokeWidth(
          activeTool,
          controller.inkStrokeWidth,
        );
        final eraserRadius = activeTool == DrawingTool.eraserBrush
            ? currentWidth / 2
            : _eraserStrokeRadius(controller.inkStrokeWidth);
        return IgnorePointer(
          ignoring: !isInkTool || !widget.interactionEnabled || _suspendInk,
          child: MouseRegion(
            cursor: _usesCustomInkCursor(controller.tool)
                ? SystemMouseCursors.basic
                : MouseCursor.defer,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) =>
                  _onPointerDown(event, controller, constraints.biggest),
              onPointerMove: (event) =>
                  _onPointerMove(event, controller, constraints.biggest),
              onPointerUp: (event) => _onPointerUp(event, controller),
              onPointerCancel: (event) => _onPointerCancel(event),
              child: ValueListenableBuilder<Offset>(
                valueListenable: controller.lassoDragDelta,
                builder: (context, lassoDelta, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _DocumentInkPainter(
                          pages: widget.pages,
                          pageSize: widget.pageSize,
                          pageGap: widget.pageGap,
                          worldOrigin: widget.worldOrigin,
                          firstPageIndex: widget.firstPageIndex,
                          lastPageIndex: widget.lastPageIndex,
                          selectedPageIndex: lassoSelection?.pageIndex,
                          selectedStrokeIds:
                              lassoSelection?.strokeIds.toSet() ?? {},
                          selectionDelta: lassoSelection == null
                              ? Offset.zero
                              : lassoDelta,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _InkOverlayPainter(
                          repaint: _inkRepaint,
                          currentPoints: _currentPoints,
                          currentColor: controller.inkColor,
                          currentWidth: currentWidth,
                          currentTool: activeTool,
                          worldOrigin: widget.worldOrigin,
                          snapHintStart: _snapHintStart,
                          snapHintEnd: _snapHintEnd,
                          eraserPosition: _eraserPosition,
                          eraserRadius: eraserRadius,
                          eraserTrail: _eraserTrail,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _onPointerDown(
    PointerDownEvent event,
    EditorController controller,
    Size viewportSize,
  ) {
    if (_primaryPointer != null) {
      if (!_shouldDelayTouchStroke(_primaryPointerKind!)) {
        return;
      }
      _activePointers.add(event.pointer);
      if (_activePointers.length > 1) {
        _suspendInk = true;
        _resetCurrent();
      }
      return;
    }
    if (_isPalmLikeTouch(event)) {
      return;
    }
    if ((controller.tool == DrawingTool.pen ||
            controller.tool == DrawingTool.highlighter) &&
        _isNearViewportEdge(event.localPosition, viewportSize)) {
      return;
    }
    final inputTool = _toolForPointerEvent(
      event,
      controller.tool,
      controller.lastEraserTool,
    );
    _activePointers.add(event.pointer);
    if (_activePointers.length > 1) {
      _suspendInk = true;
      _resetCurrent();
      return;
    }
    if (!_isInkTool(inputTool)) {
      return;
    }
    final worldOffset = _toWorld(event.localPosition);
    final pageIndex = _pageIndexAt(worldOffset);
    if (pageIndex == null) {
      _resetCurrent();
      return;
    }
    if (controller.currentPageIndex != pageIndex) {
      controller.setCurrentPage(pageIndex);
    }
    _activePageIndex = pageIndex;
    final localOffset = _toPageLocal(worldOffset, pageIndex);
    final docOffset = _toDocument(localOffset, pageIndex);
    _primaryPointer = event.pointer;
    _primaryPointerKind = event.kind;
    _activeToolOverride = inputTool == controller.tool ? null : inputTool;
    _activePointerAllowsTapStroke = _canCommitTapStroke(event.kind);
    if (_shouldDelayTouchStroke(event.kind)) {
      _pendingTouchStart = docOffset;
      _pendingTouchPageIndex = pageIndex;
      return;
    }
    _beginStrokeAt(
      docOffset,
      worldOffset,
      localOffset,
      pageIndex,
      controller,
      inputTool,
      event.pressure,
    );
  }

  void _beginStrokeAt(
    Offset docOffset,
    Offset worldOffset,
    Offset localOffset,
    int pageIndex,
    EditorController controller,
    DrawingTool tool,
    double pressure,
  ) {
    if (tool.isShape) {
      _shapeStart = docOffset;
      _currentPoints
        ..clear()
        ..addAll(_buildShapePoints(tool, _shapeStart!, _shapeStart!));
      _notifyInkChanged();
      return;
    }
    if (tool == DrawingTool.eraserStroke) {
      _eraseStrokeIds.clear();
      _eraserPosition = worldOffset;
      _eraserTrail
        ..clear()
        ..add(worldOffset);
      _eraseAt(localOffset, pageIndex);
      _notifyInkChanged();
      return;
    }
    if (tool == DrawingTool.eraserArea) {
      _currentPoints
        ..clear()
        ..add(InkPoint.fromOffset(docOffset, pressure));
      _notifyInkChanged();
      return;
    }
    if (tool == DrawingTool.eraserBrush) {
      _eraserPosition = worldOffset;
    }
    _currentPoints
      ..clear()
      ..add(InkPoint.fromOffset(docOffset, pressure));
    _snappedStraight = false;
    _snappedRect = false;
    _snappedEllipse = false;
    _rectFixedCorner = null;
    _ellipseFixedCorner = null;
    _notifyInkChanged();
    if (_isSnapTool(tool)) {
      _startSnapTimer(docOffset);
    }
  }

  void _onPointerMove(
    PointerMoveEvent event,
    EditorController controller,
    Size viewportSize,
  ) {
    if (event.pointer != _primaryPointer) {
      return;
    }
    if (_suspendInk || _activePointers.length > 1) {
      return;
    }
    final pageIndex = _activePageIndex;
    if (pageIndex == null) {
      return;
    }
    var tool = _activeTool(controller);
    final worldOffset = _toWorld(event.localPosition);
    final localOffset = _toPageLocal(worldOffset, pageIndex);
    if (!_isInsidePage(localOffset)) {
      if (tool == DrawingTool.eraserStroke || tool == DrawingTool.eraserBrush) {
        _eraserPosition = worldOffset;
        _notifyInkChanged();
      }
      return;
    }
    final docOffset = _toDocument(localOffset, pageIndex);
    if (_shouldRejectViewportEdgePoint(
      _currentPoints,
      docOffset,
      event.localPosition,
      viewportSize,
      tool,
    )) {
      return;
    }
    final pendingStart = _pendingTouchStart;
    final pendingPageIndex = _pendingTouchPageIndex;
    if (pendingStart != null) {
      if (pendingPageIndex != pageIndex ||
          (docOffset - pendingStart).distance < _touchStrokeStartSlop) {
        return;
      }
      _pendingTouchStart = null;
      _pendingTouchPageIndex = null;
      final pendingLocal = _toPageLocalFromDocument(pendingStart, pageIndex);
      _beginStrokeAt(
        pendingStart,
        _toWorldFromDocument(pendingStart),
        pendingLocal,
        pageIndex,
        controller,
        tool,
        event.pressure,
      );
    }
    tool = _syncActiveToolWithPointerMove(
      event,
      controller,
      pageIndex,
      docOffset,
      worldOffset,
      localOffset,
      tool,
    );
    if (tool == DrawingTool.eraserStroke) {
      _eraserPosition = worldOffset;
      _addEraserTrailPoint(worldOffset);
      _eraseAt(localOffset, pageIndex);
      _notifyInkChanged();
      return;
    }
    if (tool == DrawingTool.eraserArea) {
      if (_shouldAddPoint(docOffset, tool)) {
        _currentPoints.add(InkPoint.fromOffset(docOffset, event.pressure));
        _notifyInkChanged();
      }
      return;
    }
    if (tool.isShape) {
      if (_shapeStart == null) {
        return;
      }
      _currentPoints
        ..clear()
        ..addAll(_buildShapePoints(tool, _shapeStart!, docOffset));
      _notifyInkChanged();
      return;
    }
    if (_currentPoints.isEmpty) {
      return;
    }
    if (_isSnapTool(tool)) {
      _startSnapTimer(docOffset);
    }
    if (tool == DrawingTool.eraserBrush) {
      _eraserPosition = worldOffset;
      _notifyInkChanged();
    }
    if (_snappedStraight) {
      if (_currentPoints.length >= 2) {
        _currentPoints[_currentPoints.length - 1] = InkPoint.fromOffset(
          docOffset,
          event.pressure,
        );
        _notifyInkChanged();
      }
      return;
    }
    if (_snappedRect) {
      if (_currentPoints.length == 5) {
        final fixed = _rectFixedCorner ?? _currentPoints.first.toOffset();
        final points = _buildRectanglePoints(fixed, docOffset, event.pressure);
        _currentPoints
          ..clear()
          ..addAll(points);
        _notifyInkChanged();
      }
      return;
    }
    if (_snappedEllipse) {
      final fixed = _ellipseFixedCorner ?? _currentPoints.first.toOffset();
      _currentPoints
        ..clear()
        ..addAll(_buildEllipsePoints(fixed, docOffset, event.pressure));
      _notifyInkChanged();
      return;
    }
    if (!_shouldAddPoint(docOffset, tool)) {
      return;
    }
    _currentPoints.add(InkPoint.fromOffset(docOffset, event.pressure));
    _notifyInkChanged();
  }

  void _onPointerUp(PointerUpEvent event, EditorController controller) {
    _activePointers.remove(event.pointer);
    if (event.pointer != _primaryPointer) {
      if (_primaryPointer == null && _activePointers.length <= 1) {
        _suspendInk = false;
      }
      return;
    }
    if (_activePointers.length > 1) {
      _resetCurrent();
      return;
    }
    if (_suspendInk && _activePointers.length <= 1) {
      _suspendInk = false;
    }
    if (_pendingTouchStart != null) {
      _resetCurrent();
      return;
    }
    final pageIndex = _activePageIndex;
    if (pageIndex == null) {
      _resetCurrent();
      return;
    }
    final tool = _activeTool(controller);
    if (tool.isShape) {
      if (_currentPoints.isEmpty) {
        _resetCurrent();
        return;
      }
      controller.addInkStrokeOnPage(
        pageIndex,
        _toPageLocalPoints(_currentPoints, pageIndex),
        widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
        toolOverride: tool,
      );
      _resetCurrent();
      return;
    }
    if (tool == DrawingTool.eraserStroke) {
      if (_eraseStrokeIds.isNotEmpty) {
        controller.eraseInkStrokesByIdOnPage(pageIndex, _eraseStrokeIds);
        _eraseStrokeIds.clear();
      }
      _eraserPosition = null;
      _resetCurrent();
      return;
    }
    if (tool == DrawingTool.eraserArea) {
      if (_currentPoints.length >= 3) {
        controller.addInkStrokeOnPage(
          pageIndex,
          _toPageLocalPoints(_closedAreaPoints(_currentPoints), pageIndex),
          widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
          toolOverride: tool,
        );
      }
      _resetCurrent();
      return;
    }
    if (_currentPoints.isEmpty) {
      return;
    }
    _snapTimer?.cancel();
    if (_currentPoints.length == 1) {
      if (!_activePointerAllowsTapStroke) {
        _resetCurrent();
        return;
      }
      final point = _currentPoints.first;
      _currentPoints.add(
        InkPoint(dx: point.dx + 0.5, dy: point.dy, pressure: point.pressure),
      );
    }
    if (_tryCommitScratchErase(controller, pageIndex, tool)) {
      _resetCurrent();
      return;
    }
    final pageLocalPoints = _toPageLocalPoints(_currentPoints, pageIndex);
    if (tool == DrawingTool.lasso) {
      controller.selectWithLasso(
        pageLocalPoints.map((p) => p.toOffset()).toList(),
        pageIndex,
      );
    } else {
      controller.addInkStrokeOnPage(
        pageIndex,
        pageLocalPoints,
        widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
        toolOverride: tool,
      );
    }
    _resetCurrent();
  }

  DrawingTool _syncActiveToolWithPointerMove(
    PointerMoveEvent event,
    EditorController controller,
    int pageIndex,
    Offset docOffset,
    Offset worldOffset,
    Offset localOffset,
    DrawingTool currentTool,
  ) {
    final targetTool = _toolForPointerEvent(
      event,
      controller.tool,
      controller.lastEraserTool,
    );
    if (targetTool == currentTool) {
      return currentTool;
    }
    _commitCurrentSegment(
      controller,
      pageIndex,
      currentTool,
      allowTapStroke: false,
    );
    _clearCurrentSegmentForToolSwitch();
    _activeToolOverride = targetTool == controller.tool ? null : targetTool;
    _primaryPointer = event.pointer;
    _primaryPointerKind = event.kind;
    _activePointerAllowsTapStroke = _canCommitTapStroke(event.kind);
    _beginStrokeAt(
      docOffset,
      worldOffset,
      localOffset,
      pageIndex,
      controller,
      targetTool,
      event.pressure,
    );
    return targetTool;
  }

  void _commitCurrentSegment(
    EditorController controller,
    int pageIndex,
    DrawingTool tool, {
    required bool allowTapStroke,
  }) {
    _snapTimer?.cancel();
    if (tool.isShape) {
      if (_currentPoints.isNotEmpty) {
        _addCurrentStroke(controller, pageIndex, tool);
      }
      return;
    }
    if (tool == DrawingTool.eraserStroke) {
      if (_eraseStrokeIds.isNotEmpty) {
        controller.eraseInkStrokesByIdOnPage(pageIndex, _eraseStrokeIds);
      }
      return;
    }
    if (tool == DrawingTool.eraserArea) {
      if (_currentPoints.length >= 3) {
        controller.addInkStrokeOnPage(
          pageIndex,
          _toPageLocalPoints(_closedAreaPoints(_currentPoints), pageIndex),
          widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
          toolOverride: tool,
        );
      }
      return;
    }
    if (_currentPoints.isEmpty) {
      return;
    }
    if (_currentPoints.length == 1) {
      if (!allowTapStroke || !_activePointerAllowsTapStroke) {
        return;
      }
      final point = _currentPoints.first;
      _currentPoints.add(
        InkPoint(dx: point.dx + 0.5, dy: point.dy, pressure: point.pressure),
      );
    }
    final pageLocalPoints = _toPageLocalPoints(_currentPoints, pageIndex);
    if (_tryCommitScratchErase(controller, pageIndex, tool)) {
      return;
    }
    if (tool == DrawingTool.lasso) {
      controller.selectWithLasso(
        pageLocalPoints.map((p) => p.toOffset()).toList(),
        pageIndex,
      );
      return;
    }
    controller.addInkStrokeOnPage(
      pageIndex,
      pageLocalPoints,
      widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
      toolOverride: tool,
    );
  }

  void _addCurrentStroke(
    EditorController controller,
    int pageIndex,
    DrawingTool tool,
  ) {
    controller.addInkStrokeOnPage(
      pageIndex,
      _toPageLocalPoints(_currentPoints, pageIndex),
      widthOverride: _effectiveStrokeWidth(tool, controller.inkStrokeWidth),
      toolOverride: tool,
    );
  }

  bool _tryCommitScratchErase(
    EditorController controller,
    int pageIndex,
    DrawingTool tool,
  ) {
    final pointerKind = _primaryPointerKind;
    if (tool != DrawingTool.pen || pointerKind == null) {
      return false;
    }
    final result = _eraseStrokeParts(
      strokes: widget.pages[pageIndex].inkStrokes,
      gesture: _toPageLocalPoints(_currentPoints, pageIndex),
      radius: max(8.0, controller.inkStrokeWidth * _scratchEraseRadiusScale),
      createId: controller.createInkStrokeId,
    );
    if (!result.changed) {
      return false;
    }
    if (!_isScratchEraseGesture(_currentPoints, pointerKind)) {
      return false;
    }
    controller.replaceInkStrokesOnPage(pageIndex, result.strokes);
    return true;
  }

  void _clearCurrentSegmentForToolSwitch() {
    _snapTimer?.cancel();
    _snapHintTimer?.cancel();
    _eraseStrokeIds.clear();
    _eraserPosition = null;
    _eraserTrail.clear();
    _snappedStraight = false;
    _snappedRect = false;
    _snappedEllipse = false;
    _snapHintStart = null;
    _snapHintEnd = null;
    _snapAnchor = null;
    _rectFixedCorner = null;
    _ellipseFixedCorner = null;
    _shapeStart = null;
    _pendingTouchStart = null;
    _pendingTouchPageIndex = null;
    _currentPoints.clear();
    _notifyInkChanged();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer != _primaryPointer) {
      if (_primaryPointer == null && _activePointers.length <= 1) {
        _suspendInk = false;
      }
      return;
    }
    if (_activePointers.length <= 1) {
      _suspendInk = false;
    }
    _resetCurrent();
  }

  void _resetCurrent() {
    _snapTimer?.cancel();
    _snapHintTimer?.cancel();
    _eraseStrokeIds.clear();
    _eraserPosition = null;
    _eraserTrail.clear();
    _snappedStraight = false;
    _snappedRect = false;
    _snappedEllipse = false;
    _snapHintStart = null;
    _snapHintEnd = null;
    _snapAnchor = null;
    _rectFixedCorner = null;
    _ellipseFixedCorner = null;
    _shapeStart = null;
    _activePageIndex = null;
    _primaryPointer = null;
    _primaryPointerKind = null;
    _activeToolOverride = null;
    _pendingTouchStart = null;
    _pendingTouchPageIndex = null;
    _activePointerAllowsTapStroke = false;
    if (_currentPoints.isEmpty) {
      _notifyInkChanged();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _currentPoints.clear();
    _notifyInkChanged();
    if (mounted) {
      setState(() {});
    }
  }

  void _notifyInkChanged() {
    _inkRepaint.value++;
  }

  void _addEraserTrailPoint(Offset offset) {
    if (_eraserTrail.isEmpty ||
        (offset - _eraserTrail.last).distanceSquared >= 4.0) {
      _eraserTrail.add(offset);
      _trimEraserTrail(_eraserTrail);
    }
  }

  DrawingTool _activeTool(EditorController controller) {
    return _activeToolOverride ?? controller.tool;
  }

  Offset _toWorld(Offset localPosition) {
    return localPosition + widget.worldOrigin;
  }

  int? _pageIndexAt(Offset worldOffset) {
    final stride = widget.pageSize.height + widget.pageGap;
    if (stride <= 0 || widget.pages.isEmpty) {
      return null;
    }
    final dy = worldOffset.dy - widget.worldOrigin.dy;
    if (dy < 0) {
      return null;
    }
    final index = dy ~/ stride;
    if (index < 0 || index >= widget.pages.length) {
      return null;
    }
    final pageTop = index * stride;
    final pageBottom = pageTop + widget.pageSize.height;
    if (dy < pageTop || dy > pageBottom) {
      return null;
    }
    return index;
  }

  Offset _pageOrigin(int pageIndex) {
    final stride = widget.pageSize.height + widget.pageGap;
    return Offset(0, pageIndex * stride) + widget.worldOrigin;
  }

  Offset _documentPageOrigin(int pageIndex) {
    final stride = widget.pageSize.height + widget.pageGap;
    return Offset(0, pageIndex * stride);
  }

  Offset _toPageLocal(Offset worldOffset, int pageIndex) {
    return worldOffset - _pageOrigin(pageIndex);
  }

  Offset _toPageLocalFromDocument(Offset documentOffset, int pageIndex) {
    return documentOffset - _documentPageOrigin(pageIndex);
  }

  Offset _toDocument(Offset pageLocal, int pageIndex) {
    return pageLocal + _pageOrigin(pageIndex) - widget.worldOrigin;
  }

  Offset _toWorldFromDocument(Offset documentOffset) {
    return documentOffset + widget.worldOrigin;
  }

  bool _isInsidePage(Offset pageLocal) {
    return pageLocal.dx >= 0 &&
        pageLocal.dy >= 0 &&
        pageLocal.dx <= widget.pageSize.width &&
        pageLocal.dy <= widget.pageSize.height;
  }

  bool _shouldAddPoint(Offset offset, DrawingTool tool) {
    return _shouldAcceptInkPoint(_currentPoints, offset, tool);
  }

  bool _shouldDelayTouchStroke(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch;
  }

  bool _canCommitTapStroke(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus ||
        kind == PointerDeviceKind.mouse;
  }

  bool _isPalmLikeTouch(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return false;
    }
    return max(event.radiusMajor, event.radiusMinor) >= _palmContactRadius;
  }

  void _startSnapTimer(Offset offset) {
    const jitterTolerance = 20.0;
    if (_snapAnchor == null ||
        (offset - _snapAnchor!).distance > jitterTolerance) {
      _snapAnchor = offset;
      _snapTimer?.cancel();
      _snapTimer = Timer(const Duration(milliseconds: 1200), _snapToShape);
    }
  }

  void _eraseAt(Offset localOffset, int pageIndex) {
    final page = widget.pages[pageIndex];
    final radius = _eraserStrokeRadius(
      context.read<EditorController>().inkStrokeWidth,
    );
    for (final stroke in page.inkStrokes) {
      if (_eraseStrokeIds.contains(stroke.id)) {
        continue;
      }
      if (_strokeHitTest(stroke, localOffset, radius)) {
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

  List<InkPoint> _toPageLocalPoints(List<InkPoint> points, int pageIndex) {
    final origin = _pageOrigin(pageIndex) - widget.worldOrigin;
    return points
        .map(
          (point) => InkPoint(
            dx: point.dx - origin.dx,
            dy: point.dy - origin.dy,
            pressure: point.pressure,
          ),
        )
        .toList();
  }

  void _snapToShape() {
    if (_currentPoints.length < 2 ||
        _snappedStraight ||
        _snappedRect ||
        _snappedEllipse) {
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

  bool _isRoughlyStraight(Offset start, Offset end, List<InkPoint> points) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = sqrt(dx * dx + dy * dy);
    if (length < 2) {
      return false;
    }
    final maxDistance = max(8.0, length * 0.08);
    for (final point in points) {
      final offset = point.toOffset();
      final distance =
          ((dy * offset.dx -
                  dx * offset.dy +
                  end.dx * start.dy -
                  end.dy * start.dx)
              .abs()) /
          length;
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

  bool _usesCustomInkCursor(DrawingTool tool) {
    return tool == DrawingTool.pen || tool == DrawingTool.highlighter;
  }

  double _effectiveStrokeWidth(DrawingTool tool, double baseWidth) {
    if (tool == DrawingTool.highlighter) {
      return baseWidth * 8.0;
    }
    if (tool == DrawingTool.eraserBrush) {
      return baseWidth * _eraserBrushWidthScale;
    }
    if (tool == DrawingTool.eraserArea) {
      return max(1.5, baseWidth * 0.5);
    }
    return baseWidth;
  }

  List<InkPoint> _buildShapePoints(DrawingTool tool, Offset start, Offset end) {
    switch (tool) {
      case DrawingTool.line:
        return [InkPoint.fromOffset(start, 1.0), InkPoint.fromOffset(end, 1.0)];
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
        return [InkPoint.fromOffset(start, 1.0), InkPoint.fromOffset(end, 1.0)];
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
      return [InkPoint.fromOffset(start, 1.0), InkPoint.fromOffset(end, 1.0)];
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
      return _buildRectanglePoints(
        Offset(left, top),
        Offset(right, bottom),
        1.0,
      );
    }

    final minBodyWidth = max(6.0, width * 0.15);
    var headWidth = max(12.0, width * 0.35);
    if (headWidth > width - minBodyWidth) {
      headWidth = width - minBodyWidth;
    }
    if (headWidth <= 0) {
      return _buildRectanglePoints(
        Offset(left, top),
        Offset(right, bottom),
        1.0,
      );
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
    required this.worldOrigin,
    required this.selectedStrokeIds,
    required this.selectionDelta,
  });

  final List<InkStroke> strokes;
  final Offset worldOrigin;
  final Set<String> selectedStrokeIds;
  final Offset selectionDelta;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in strokes) {
      final isSelected = selectedStrokeIds.contains(stroke.id);
      _drawStroke(
        canvas,
        stroke.points,
        stroke.color,
        stroke.width,
        stroke.tool,
        isSelected: isSelected,
        delta: isSelected ? selectionDelta : Offset.zero,
      );
    }
    canvas.restore();
  }

  void _drawStroke(
    Canvas canvas,
    List<InkPoint> points,
    Color color,
    double width,
    DrawingTool tool, {
    bool isSelected = false,
    Offset delta = Offset.zero,
  }) {
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
    if (tool == DrawingTool.eraserArea) {
      paint
        ..color = Colors.transparent
        ..blendMode = BlendMode.clear
        ..style = PaintingStyle.fill;
    } else if (tool == DrawingTool.eraserBrush) {
      paint
        ..color = Colors.transparent
        ..blendMode = BlendMode.clear;
    } else {
      paint.color = _toolColor(color, tool);
    }

    final path = _buildInkPath(points, tool, Offset.zero, worldOrigin, delta);
    if (isSelected) {
      final highlightPaint = Paint()
        ..color = Colors.blue.withValues(alpha: 0.24)
        ..strokeCap = tool == DrawingTool.highlighter
            ? StrokeCap.square
            : StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = width + 8.0;
      canvas.drawPath(path, highlightPaint);
    }
    if (tool == DrawingTool.eraserArea) {
      canvas.drawPath(path..close(), paint);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  Color _toolColor(Color base, DrawingTool tool) {
    if (tool == DrawingTool.lasso) {
      return const Color(0x882196F3); // Semi-transparent blue for lasso
    }
    if (tool == DrawingTool.highlighter) {
      return base.withValues(alpha: 0.5);
    }
    return base;
  }

  @override
  bool shouldRepaint(covariant _InkPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.selectedStrokeIds != selectedStrokeIds ||
        oldDelegate.selectionDelta != selectionDelta;
  }
}

class _InkOverlayPainter extends CustomPainter {
  _InkOverlayPainter({
    required Listenable repaint,
    required this.currentPoints,
    required this.currentColor,
    required this.currentWidth,
    required this.currentTool,
    required this.worldOrigin,
    this.snapHintStart,
    this.snapHintEnd,
    this.eraserPosition,
    this.eraserRadius,
    this.eraserTrail = const <Offset>[],
  }) : super(repaint: repaint);

  final List<InkPoint> currentPoints;
  final Color currentColor;
  final double currentWidth;
  final DrawingTool currentTool;
  final Offset worldOrigin;
  final Offset? snapHintStart;
  final Offset? snapHintEnd;
  final Offset? eraserPosition;
  final double? eraserRadius;
  final List<Offset> eraserTrail;

  @override
  void paint(Canvas canvas, Size size) {
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

    if (currentTool == DrawingTool.eraserStroke && eraserTrail.isNotEmpty) {
      _drawEraserTrail(canvas, size, eraserTrail, eraserRadius ?? 12.0);
    }
  }

  void _drawEraserTrail(
    Canvas canvas,
    Size size,
    List<Offset> points,
    double radius,
  ) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.13)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 2
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.25);
    if (points.length < 2) {
      return;
    }

    final path = Path()
      ..moveTo(
        points.first.dx - worldOrigin.dx,
        points.first.dy - worldOrigin.dy,
      );
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx - worldOrigin.dx, points[i].dy - worldOrigin.dy);
    }

    final fadeStart = points.first - worldOrigin;
    final fadeEnd =
        _pointAlongTrail(points, _eraserTrailMaxLength * 0.45) - worldOrigin;
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawPath(path, paint);
    final maskPaint = Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = ui.Gradient.linear(fadeStart, fadeEnd, <Color>[
        Colors.transparent,
        Colors.black,
      ]);
    canvas.drawRect(Offset.zero & size, maskPaint);
    canvas.restore();
  }

  Offset _pointAlongTrail(List<Offset> points, double distance) {
    var remaining = distance;
    for (var i = 1; i < points.length; i++) {
      final start = points[i - 1];
      final end = points[i];
      final segment = (end - start).distance;
      if (segment >= remaining) {
        final t = segment == 0 ? 0.0 : remaining / segment;
        return Offset.lerp(start, end, t)!;
      }
      remaining -= segment;
    }
    return points.last;
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
    if (tool == DrawingTool.eraserArea && points.length < 3) {
      _drawEraserAreaStart(canvas, points, width);
      return;
    }
    final paint = Paint()
      ..strokeCap = tool == DrawingTool.highlighter
          ? StrokeCap.square
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    if (tool == DrawingTool.eraserArea) {
      paint
        ..color = _canvasBackgroundColor.withValues(alpha: 0.32)
        ..style = PaintingStyle.fill;
    } else if (tool == DrawingTool.eraserBrush) {
      paint.color = _canvasBackgroundColor;
    } else {
      paint.color = _toolColor(color, tool);
    }

    final path = _buildInkPath(
      points,
      tool,
      Offset.zero,
      worldOrigin,
      Offset.zero,
    );
    if (tool == DrawingTool.eraserArea) {
      final closedPath = path..close();
      canvas.drawPath(closedPath, paint);
      final outlinePaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.2, width);
      canvas.drawPath(closedPath, outlinePaint);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  void _drawEraserAreaStart(
    Canvas canvas,
    List<InkPoint> points,
    double width,
  ) {
    final radius = max(5.0, width * 3.0);
    final fillPaint = Paint()
      ..color = _canvasBackgroundColor.withValues(alpha: 0.32)
      ..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.2, width);
    final start = points.first.toOffset() - worldOrigin;
    canvas.drawCircle(start, radius, fillPaint);
    if (points.length == 1) {
      canvas.drawCircle(start, radius, outlinePaint);
      return;
    }
    final end = points.last.toOffset() - worldOrigin;
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(end.dx, end.dy);
    canvas.drawPath(path, outlinePaint);
    canvas.drawCircle(start, radius, outlinePaint);
    canvas.drawCircle(end, radius, outlinePaint);
  }

  Color _toolColor(Color base, DrawingTool tool) {
    if (tool == DrawingTool.lasso) {
      return const Color(0x882196F3); // Semi-transparent blue for lasso
    }
    if (tool == DrawingTool.highlighter) {
      return base.withValues(alpha: 0.5);
    }
    return base;
  }

  @override
  bool shouldRepaint(covariant _InkOverlayPainter oldDelegate) {
    return oldDelegate.currentColor != currentColor ||
        oldDelegate.currentWidth != currentWidth ||
        oldDelegate.currentTool != currentTool ||
        oldDelegate.worldOrigin != worldOrigin ||
        oldDelegate.snapHintStart != snapHintStart ||
        oldDelegate.snapHintEnd != snapHintEnd ||
        oldDelegate.eraserPosition != eraserPosition ||
        oldDelegate.eraserRadius != eraserRadius ||
        oldDelegate.eraserTrail != eraserTrail;
  }
}

class _DocumentInkPainter extends CustomPainter {
  _DocumentInkPainter({
    required this.pages,
    required this.pageSize,
    required this.pageGap,
    required this.worldOrigin,
    required this.firstPageIndex,
    required this.lastPageIndex,
    required this.selectedPageIndex,
    required this.selectedStrokeIds,
    required this.selectionDelta,
  });

  final List<NotePage> pages;
  final Size pageSize;
  final double pageGap;
  final Offset worldOrigin;
  final int firstPageIndex;
  final int? lastPageIndex;
  final int? selectedPageIndex;
  final Set<String> selectedStrokeIds;
  final Offset selectionDelta;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    final start = firstPageIndex.clamp(0, pages.length).toInt();
    final end = (lastPageIndex ?? pages.length)
        .clamp(start, pages.length)
        .toInt();
    for (var i = start; i < end; i++) {
      final origin = _pageOrigin(i);
      for (final stroke in pages[i].inkStrokes) {
        final isSelected =
            selectedPageIndex == i && selectedStrokeIds.contains(stroke.id);
        _drawStroke(
          canvas,
          stroke.points,
          stroke.color,
          stroke.width,
          stroke.tool,
          origin,
          isSelected: isSelected,
          delta: isSelected ? selectionDelta : Offset.zero,
        );
      }
    }
    canvas.restore();
  }

  Offset _pageOrigin(int index) {
    final stride = pageSize.height + pageGap;
    return Offset(0, index * stride);
  }

  void _drawStroke(
    Canvas canvas,
    List<InkPoint> points,
    Color color,
    double width,
    DrawingTool tool,
    Offset origin, {
    bool isSelected = false,
    Offset delta = Offset.zero,
  }) {
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
    if (tool == DrawingTool.eraserArea) {
      paint
        ..color = Colors.transparent
        ..blendMode = BlendMode.clear
        ..style = PaintingStyle.fill;
    } else if (tool == DrawingTool.eraserBrush) {
      paint
        ..color = Colors.transparent
        ..blendMode = BlendMode.clear;
    } else {
      paint.color = _toolColor(color, tool);
    }

    final path = _buildInkPath(points, tool, origin, worldOrigin, delta);
    if (isSelected) {
      final highlightPaint = Paint()
        ..color = Colors.blue.withValues(alpha: 0.24)
        ..strokeCap = tool == DrawingTool.highlighter
            ? StrokeCap.square
            : StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = width + 8.0;
      canvas.drawPath(path, highlightPaint);
    }
    if (tool == DrawingTool.eraserArea) {
      canvas.drawPath(path..close(), paint);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  Color _toolColor(Color base, DrawingTool tool) {
    if (tool == DrawingTool.lasso) {
      return const Color(0x882196F3); // Semi-transparent blue for lasso
    }
    if (tool == DrawingTool.highlighter) {
      return base.withValues(alpha: 0.5);
    }
    return base;
  }

  @override
  bool shouldRepaint(covariant _DocumentInkPainter oldDelegate) {
    return oldDelegate.pages != pages ||
        oldDelegate.pageSize != pageSize ||
        oldDelegate.pageGap != pageGap ||
        oldDelegate.firstPageIndex != firstPageIndex ||
        oldDelegate.lastPageIndex != lastPageIndex ||
        oldDelegate.selectedPageIndex != selectedPageIndex ||
        oldDelegate.selectedStrokeIds != selectedStrokeIds ||
        oldDelegate.selectionDelta != selectionDelta ||
        oldDelegate.worldOrigin != worldOrigin;
  }
}
