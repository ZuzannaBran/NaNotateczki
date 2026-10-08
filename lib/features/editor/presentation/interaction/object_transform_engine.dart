import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';

enum ObjectTransformKind { move, resize }

class ObjectTransformSnapshot {
  const ObjectTransformSnapshot({
    required this.kind,
    required this.rect,
    required this.rotation,
    this.handle,
    this.resizeMode,
  });

  final ObjectTransformKind kind;
  final Rect rect;
  final double rotation;
  final HandlePosition? handle;
  final ResizeMode? resizeMode;
}

class ObjectTransformEngine {
  _ObjectTransformSession? _session;
  ObjectTransformSnapshot? _lastPreview;

  bool get isActive => _session != null;

  ObjectTransformKind? get kind => _session?.kind;

  void beginMove({
    required Rect rect,
    required double rotation,
    required Offset pointer,
    Rect clampingRect = Rect.largest,
  }) {
    _begin(
      _ObjectTransformSession(
        kind: ObjectTransformKind.move,
        initialRect: rect,
        initialRotation: rotation,
        pointerStart: pointer,
        clampingRect: clampingRect,
      ),
    );
  }

  void beginResize({
    required Rect rect,
    required double rotation,
    required Offset pointer,
    required HandlePosition handle,
    required ResizeMode resizeMode,
    BoxConstraints constraints = const BoxConstraints(),
    Rect clampingRect = Rect.largest,
  }) {
    _begin(
      _ObjectTransformSession(
        kind: ObjectTransformKind.resize,
        initialRect: rect,
        initialRotation: rotation,
        pointerStart: pointer,
        handle: handle,
        resizeMode: resizeMode,
        constraints: constraints,
        clampingRect: clampingRect,
      ),
    );
  }

  ObjectTransformSnapshot update(Offset pointer) {
    final session = _session;
    if (session == null) {
      throw StateError('ObjectTransformEngine.update called without begin');
    }

    final preview = switch (session.kind) {
      ObjectTransformKind.move => _move(session, pointer),
      ObjectTransformKind.resize => _resize(session, pointer),
    };
    _lastPreview = preview;
    return preview;
  }

  ObjectTransformSnapshot? end() {
    final result = _lastPreview;
    _session = null;
    _lastPreview = null;
    return result;
  }

  void cancel() {
    _session = null;
    _lastPreview = null;
  }

  void _begin(_ObjectTransformSession session) {
    _session = session;
    _lastPreview = ObjectTransformSnapshot(
      kind: session.kind,
      rect: session.initialRect,
      rotation: session.initialRotation,
      handle: session.handle,
      resizeMode: session.resizeMode,
    );
  }

  ObjectTransformSnapshot _move(
    _ObjectTransformSession session,
    Offset pointer,
  ) {
    final delta = pointer - session.pointerStart;
    var rect = session.initialRect.shift(delta);
    rect = _clampMovedRect(rect, session.clampingRect);
    return ObjectTransformSnapshot(
      kind: ObjectTransformKind.move,
      rect: rect,
      rotation: session.initialRotation,
    );
  }

  ObjectTransformSnapshot _resize(
    _ObjectTransformSession session,
    Offset pointer,
  ) {
    final handle = session.handle!;
    final resizeMode = session.resizeMode!;
    final rect = resizeMode.isScalable && handle.isDiagonal
        ? _scaleFromCorner(session, pointer)
        : _resizeFreeform(session, pointer);
    return ObjectTransformSnapshot(
      kind: ObjectTransformKind.resize,
      rect: rect,
      rotation: session.initialRotation,
      handle: handle,
      resizeMode: resizeMode,
    );
  }

  Rect _scaleFromCorner(_ObjectTransformSession session, Offset pointer) {
    final rect = session.initialRect;
    final handle = session.handle!;
    final anchor = _pointForHandle(
      rect,
      session.initialRotation,
      handle.opposite,
    );
    final dragged = _pointForHandle(rect, session.initialRotation, handle);
    final baseVector = dragged - anchor;
    final denominator = _dot(baseVector, baseVector);
    if (denominator <= 1e-9) {
      return rect;
    }

    var scale = _dot(pointer - anchor, baseVector) / denominator;
    final minScale = math.max(
      session.constraints.minWidth / rect.width,
      session.constraints.minHeight / rect.height,
    );
    final maxScale = math.min(
      session.constraints.maxWidth / rect.width,
      session.constraints.maxHeight / rect.height,
    );
    scale = scale.clamp(minScale, maxScale).toDouble();

    final width = rect.width * scale;
    final height = rect.height * scale;
    final center = anchor + baseVector * (scale / 2);
    return Rect.fromCenter(center: center, width: width, height: height);
  }

  Rect _resizeFreeform(_ObjectTransformSession session, Offset pointer) {
    final rect = session.initialRect;
    final handle = session.handle!;
    final rotation = session.initialRotation;
    final axisX = Offset(math.cos(rotation), math.sin(rotation));
    final axisY = Offset(-math.sin(rotation), math.cos(rotation));

    if (session.resizeMode!.hasSymmetry) {
      return _resizeSymmetric(session, pointer, axisX, axisY);
    }

    final anchor = _pointForHandle(rect, rotation, handle.opposite);
    var width = rect.width;
    var height = rect.height;

    if (handle.influencesHorizontal) {
      final sign = handle.influencesRight ? 1.0 : -1.0;
      width = _dot(pointer - anchor, axisX) * sign;
      width = session.constraints.constrainWidth(width);
    }
    if (handle.influencesVertical) {
      final sign = handle.influencesBottom ? 1.0 : -1.0;
      height = _dot(pointer - anchor, axisY) * sign;
      height = session.constraints.constrainHeight(height);
    }

    final horizontalSign = handle.influencesRight
        ? 1.0
        : handle.influencesLeft
        ? -1.0
        : 0.0;
    final verticalSign = handle.influencesBottom
        ? 1.0
        : handle.influencesTop
        ? -1.0
        : 0.0;

    var center = anchor;
    if (handle.influencesHorizontal) {
      center += axisX * (horizontalSign * width / 2);
    }
    if (handle.influencesVertical) {
      center += axisY * (verticalSign * height / 2);
    }

    if (!handle.influencesHorizontal) {
      center += axisX * _dot(rect.center - anchor, axisX);
    }
    if (!handle.influencesVertical) {
      center += axisY * _dot(rect.center - anchor, axisY);
    }

    var next = Rect.fromCenter(center: center, width: width, height: height);
    next = _clampResizeRect(next, handle, session.clampingRect, rotation);
    return next;
  }

  Rect _resizeSymmetric(
    _ObjectTransformSession session,
    Offset pointer,
    Offset axisX,
    Offset axisY,
  ) {
    final rect = session.initialRect;
    final handle = session.handle!;
    final delta = pointer - rect.center;
    var width = rect.width;
    var height = rect.height;

    if (handle.influencesHorizontal) {
      width = session.constraints.constrainWidth(2 * _dot(delta, axisX).abs());
    }
    if (handle.influencesVertical) {
      height = session.constraints.constrainHeight(
        2 * _dot(delta, axisY).abs(),
      );
    }

    if (session.resizeMode == ResizeMode.symmetricScale && handle.isDiagonal) {
      final widthScale = width / rect.width;
      final heightScale = height / rect.height;
      final scale = math.max(widthScale, heightScale).toDouble();
      width = session.constraints.constrainWidth(rect.width * scale);
      height = session.constraints.constrainHeight(rect.height * scale);
    }

    return Rect.fromCenter(center: rect.center, width: width, height: height);
  }


}

class _ObjectTransformSession {
  const _ObjectTransformSession({
    required this.kind,
    required this.initialRect,
    required this.initialRotation,
    required this.pointerStart,
    this.handle,
    this.resizeMode,
    this.constraints = const BoxConstraints(),
    this.clampingRect = Rect.largest,
  });

  final ObjectTransformKind kind;
  final Rect initialRect;
  final double initialRotation;
  final Offset pointerStart;
  final HandlePosition? handle;
  final ResizeMode? resizeMode;
  final BoxConstraints constraints;
  final Rect clampingRect;
}

Rect _clampMovedRect(Rect rect, Rect bounds) {
  if (bounds == Rect.largest) {
    return rect;
  }
  var dx = 0.0;
  var dy = 0.0;
  if (rect.left < bounds.left) {
    dx = bounds.left - rect.left;
  } else if (rect.right > bounds.right) {
    dx = bounds.right - rect.right;
  }
  if (rect.top < bounds.top) {
    dy = bounds.top - rect.top;
  } else if (rect.bottom > bounds.bottom) {
    dy = bounds.bottom - rect.bottom;
  }
  return rect.shift(Offset(dx, dy));
}

Rect _clampResizeRect(
  Rect rect,
  HandlePosition handle,
  Rect bounds,
  double rotation,
) {
  if (bounds == Rect.largest || rotation.abs() > 1e-9) {
    return rect;
  }

  var left = rect.left;
  var top = rect.top;
  var right = rect.right;
  var bottom = rect.bottom;

  if (handle.influencesLeft) {
    left = math.max(left, bounds.left).toDouble();
  }
  if (handle.influencesRight) {
    right = math.min(right, bounds.right).toDouble();
  }
  if (handle.influencesTop) {
    top = math.max(top, bounds.top).toDouble();
  }
  if (handle.influencesBottom) {
    bottom = math.min(bottom, bounds.bottom).toDouble();
  }

  if (right <= left || bottom <= top) {
    return rect;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

Offset _pointForHandle(Rect rect, double rotation, HandlePosition handle) {
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

Offset _rotate(Offset value, double angle) {
  final cosAngle = math.cos(angle);
  final sinAngle = math.sin(angle);
  return Offset(
    value.dx * cosAngle - value.dy * sinAngle,
    value.dx * sinAngle + value.dy * cosAngle,
  );
}

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;
