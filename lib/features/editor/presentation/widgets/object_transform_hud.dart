import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';

import '../interaction/object_transform_engine.dart';

typedef ObjectResizeModeResolver = ResizeMode Function(HandlePosition handle);

class ObjectTransformHudStyle {
  const ObjectTransformHudStyle({
    this.frameColor,
    this.handleFillColor,
    this.cornerHandleSize = 10,
    this.sideHandleLength = 24,
    this.sideHandleThickness = 6,
    this.rotationHandleSize = 20,
    this.handleHitSize = 32,
    this.rotationHandleOffset = 30,
    this.frameWidth = 1.25,
  });

  final Color? frameColor;
  final Color? handleFillColor;
  final double cornerHandleSize;
  final double sideHandleLength;
  final double sideHandleThickness;
  final double rotationHandleSize;
  final double handleHitSize;
  final double rotationHandleOffset;
  final double frameWidth;
}

class ObjectTransformHud<T> extends StatefulWidget {
  const ObjectTransformHud({
    required this.data,
    required this.rect,
    required this.rotation,
    required this.onPreview,
    required this.onCommit,
    this.onCancel,
    this.resizeModeResolver,
    this.constraints = const BoxConstraints(),
    this.enabledHandles = const {...HandlePosition.values},
    this.draggable = true,
    this.rotatable = true,
    this.interactive = true,
    this.showFrame = true,
    this.showHandles = true,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTapDown,
    this.style = const ObjectTransformHudStyle(),
    super.key,
  });

  final T data;
  final Rect rect;
  final double rotation;
  final void Function(T before, ObjectTransformSnapshot preview) onPreview;
  final void Function(T before, ObjectTransformSnapshot preview) onCommit;
  final ValueChanged<T>? onCancel;
  final ObjectResizeModeResolver? resizeModeResolver;
  final BoxConstraints constraints;
  final Set<HandlePosition> enabledHandles;
  final bool draggable;
  final bool rotatable;
  final bool interactive;
  final bool showFrame;
  final bool showHandles;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final ObjectTransformHudStyle style;

  @override
  State<ObjectTransformHud<T>> createState() => _ObjectTransformHudState<T>();
}

class _ObjectTransformHudState<T> extends State<ObjectTransformHud<T>> {
  final GlobalKey _surfaceKey = GlobalKey();
  final ObjectTransformEngine _engine = ObjectTransformEngine();

  ObjectTransformSnapshot? _preview;
  T? _gestureData;
  double _screenScale = 1;
  bool _scaleMeasureScheduled = false;

  @override
  Widget build(BuildContext context) {
    _scheduleScreenScaleMeasure();
    final effective = _preview ??
        ObjectTransformSnapshot(
          kind: ObjectTransformKind.move,
          rect: widget.rect,
          rotation: widget.rotation,
        );
    final rect = effective.rect;
    final rotation = effective.rotation;
    final scale = _screenScale <= 0 ? 1.0 : _screenScale;
    final style = widget.style;
    final frameColor =
        style.frameColor ?? Theme.of(context).colorScheme.primary;
    final handleFill =
        style.handleFillColor ?? Theme.of(context).colorScheme.surface;

    return Positioned.fill(
      child: SizedBox.expand(
        key: _surfaceKey,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (widget.showFrame)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ObjectTransformFramePainter(
                      rect: rect,
                      rotation: rotation,
                      color: frameColor,
                      strokeWidth: style.frameWidth / scale,
                    ),
                  ),
                ),
              ),
            if (widget.interactive && widget.draggable)
              _buildBodyGesture(rect, rotation),
            if (widget.interactive && widget.showHandles) ...[
              for (final handle in HandlePosition.corners)
                if (widget.enabledHandles.contains(handle))
                  _buildCornerHandle(
                    handle: handle,
                    rect: rect,
                    rotation: rotation,
                    frameColor: frameColor,
                    fillColor: handleFill,
                    scale: scale,
                  ),
              for (final handle in HandlePosition.sides)
                if (widget.enabledHandles.contains(handle))
                  _buildSideHandle(
                    handle: handle,
                    rect: rect,
                    rotation: rotation,
                    frameColor: frameColor,
                    fillColor: handleFill,
                    scale: scale,
                  ),
              if (widget.rotatable)
                _buildRotationHandle(
                  rect: rect,
                  rotation: rotation,
                  frameColor: frameColor,
                  fillColor: handleFill,
                  scale: scale,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBodyGesture(Rect rect, double rotation) {
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Transform.rotate(
        angle: rotation,
        alignment: Alignment.center,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          onSecondaryTapDown: widget.onSecondaryTapDown,
          onPanStart: (details) {
            _gestureData = widget.data;
            _engine.beginMove(
              rect: rect,
              rotation: rotation,
              pointer: _globalToLocal(details.globalPosition),
            );
          },
          onPanUpdate: (details) {
            _updatePreview(details.globalPosition);
          },
          onPanEnd: (_) {
            _commitGesture();
          },
          onPanCancel: _cancelGesture,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _buildCornerHandle({
    required HandlePosition handle,
    required Rect rect,
    required double rotation,
    required Color frameColor,
    required Color fillColor,
    required double scale,
  }) {
    final point = _pointForHandle(rect, rotation, handle);
    final hitSize = widget.style.handleHitSize / scale;
    return _positionedHandle(
      point: point,
      hitSize: hitSize,
      cursor: _cursorForHandle(handle),
      onPanStart: (details) {
        _beginResize(handle, rect, rotation, details.globalPosition);
      },
      child: DefaultCornerHandle(
        handle: handle,
        size: widget.style.cornerHandleSize / scale,
        decoration: BoxDecoration(
          color: fillColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: frameColor,
            width: 1.2 / scale,
          ),
        ),
      ),
    );
  }

  Widget _buildSideHandle({
    required HandlePosition handle,
    required Rect rect,
    required double rotation,
    required Color frameColor,
    required Color fillColor,
    required double scale,
  }) {
    final point = _pointForHandle(rect, rotation, handle);
    final hitSize = widget.style.handleHitSize / scale;
    return _positionedHandle(
      point: point,
      hitSize: hitSize,
      cursor: _cursorForHandle(handle),
      onPanStart: (details) {
        _beginResize(handle, rect, rotation, details.globalPosition);
      },
      child: DefaultSideHandle(
        handle: handle,
        length: widget.style.sideHandleLength / scale,
        thickness: widget.style.sideHandleThickness / scale,
        decoration: ShapeDecoration(
          color: fillColor,
          shape: StadiumBorder(
            side: BorderSide(
              color: frameColor,
              width: 1.2 / scale,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRotationHandle({
    required Rect rect,
    required double rotation,
    required Color frameColor,
    required Color fillColor,
    required double scale,
  }) {
    final topCenter = _pointForHandle(
      rect,
      rotation,
      HandlePosition.top,
    );
    final outward = _rotate(const Offset(0, -1), rotation);
    final point = topCenter +
        outward * (widget.style.rotationHandleOffset / scale);
    final hitSize = widget.style.handleHitSize / scale;

    return _positionedHandle(
      point: point,
      hitSize: hitSize,
      cursor: SystemMouseCursors.grab,
      onPanStart: (details) {
        _gestureData = widget.data;
        _engine.beginRotate(
          rect: rect,
          rotation: rotation,
          pointer: _globalToLocal(details.globalPosition),
        );
      },
      child: DefaultRotationHandle(
        size: widget.style.rotationHandleSize / scale,
        iconColor: frameColor,
        decoration: BoxDecoration(
          color: fillColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: frameColor,
            width: 1.2 / scale,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 2 / scale,
              offset: Offset(0, 1 / scale),
            ),
          ],
        ),
      ),
    );
  }

  Widget _positionedHandle({
    required Offset point,
    required double hitSize,
    required MouseCursor cursor,
    required GestureDragStartCallback onPanStart,
    required Widget child,
  }) {
    return Positioned(
      left: point.dx - hitSize / 2,
      top: point.dy - hitSize / 2,
      width: hitSize,
      height: hitSize,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: onPanStart,
          onPanUpdate: (details) {
            _updatePreview(details.globalPosition);
          },
          onPanEnd: (_) {
            _commitGesture();
          },
          onPanCancel: _cancelGesture,
          child: Center(child: child),
        ),
      ),
    );
  }

  void _beginResize(
    HandlePosition handle,
    Rect rect,
    double rotation,
    Offset globalPosition,
  ) {
    _gestureData = widget.data;
    _engine.beginResize(
      rect: rect,
      rotation: rotation,
      pointer: _globalToLocal(globalPosition),
      handle: handle,
      resizeMode:
          widget.resizeModeResolver?.call(handle) ?? ResizeMode.freeform,
      constraints: widget.constraints,
    );
  }

  void _updatePreview(Offset globalPosition) {
    if (!_engine.isActive) {
      return;
    }
    final preview = _engine.update(
      _globalToLocal(globalPosition),
      snapRotation: HardwareKeyboard.instance.isShiftPressed,
    );
    setState(() {
      _preview = preview;
    });
    final data = _gestureData;
    if (data != null) {
      widget.onPreview(data, preview);
    }
  }

  void _commitGesture() {
    if (!_engine.isActive) {
      return;
    }
    final preview = _engine.end();
    final data = _gestureData;
    _gestureData = null;
    if (preview != null && data != null) {
      widget.onCommit(data, preview);
    }
    if (mounted) {
      setState(() {
        _preview = null;
      });
    }
  }

  void _cancelGesture() {
    if (!_engine.isActive) {
      return;
    }
    _engine.cancel();
    final data = _gestureData;
    _gestureData = null;
    if (data != null) {
      widget.onCancel?.call(data);
    }
    if (mounted) {
      setState(() {
        _preview = null;
      });
    }
  }

  Offset _globalToLocal(Offset point) {
    final renderObject =
        _surfaceKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox) {
      return renderObject.globalToLocal(point);
    }
    return point;
  }

  void _scheduleScreenScaleMeasure() {
    if (_scaleMeasureScheduled) {
      return;
    }
    _scaleMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scaleMeasureScheduled = false;
      if (!mounted) {
        return;
      }
      final renderObject =
          _surfaceKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox) {
        return;
      }
      final origin = renderObject.localToGlobal(Offset.zero);
      final xUnit = renderObject.localToGlobal(const Offset(1, 0));
      final yUnit = renderObject.localToGlobal(const Offset(0, 1));
      final measured = math.max(
        0.01,
        ((xUnit - origin).distance + (yUnit - origin).distance) / 2,
      );
      if ((measured - _screenScale).abs() <= 0.01) {
        return;
      }
      setState(() {
        _screenScale = measured;
      });
    });
  }

  Offset _pointForHandle(
    Rect rect,
    double rotation,
    HandlePosition handle,
  ) {
    final point = switch (handle) {
      HandlePosition.topLeft => rect.topLeft,
      HandlePosition.top => rect.topCenter,
      HandlePosition.topRight => rect.topRight,
      HandlePosition.left => rect.centerLeft,
      HandlePosition.right => rect.centerRight,
      HandlePosition.bottomLeft => rect.bottomLeft,
      HandlePosition.bottom => rect.bottomCenter,
      HandlePosition.bottomRight => rect.bottomRight,
      HandlePosition.none => rect.center,
    };
    return rect.center + _rotate(point - rect.center, rotation);
  }

  MouseCursor _cursorForHandle(HandlePosition handle) {
    return switch (handle) {
      HandlePosition.left ||
      HandlePosition.right => SystemMouseCursors.resizeLeftRight,
      HandlePosition.top ||
      HandlePosition.bottom => SystemMouseCursors.resizeUpDown,
      HandlePosition.topLeft ||
      HandlePosition.bottomRight =>
        SystemMouseCursors.resizeUpLeftDownRight,
      HandlePosition.topRight ||
      HandlePosition.bottomLeft =>
        SystemMouseCursors.resizeUpRightDownLeft,
      HandlePosition.none => SystemMouseCursors.basic,
    };
  }
}

class _ObjectTransformFramePainter extends CustomPainter {
  const _ObjectTransformFramePainter({
    required this.rect,
    required this.rotation,
    required this.color,
    required this.strokeWidth,
  });

  final Rect rect;
  final double rotation;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      _rotateAround(rect.topLeft, rect.center, rotation),
      _rotateAround(rect.topRight, rect.center, rotation),
      _rotateAround(rect.bottomRight, rect.center, rotation),
      _rotateAround(rect.bottomLeft, rect.center, rotation),
    ];
    final path = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ObjectTransformFramePainter oldDelegate) {
    return oldDelegate.rect != rect ||
        oldDelegate.rotation != rotation ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

Offset _rotate(Offset value, double angle) {
  final cosAngle = math.cos(angle);
  final sinAngle = math.sin(angle);
  return Offset(
    value.dx * cosAngle - value.dy * sinAngle,
    value.dx * sinAngle + value.dy * cosAngle,
  );
}

Offset _rotateAround(Offset point, Offset center, double angle) {
  return center + _rotate(point - center, angle);
}
