import 'dart:math' as math;
import 'dart:ui';

enum TextHudOperation {
  translate,
  resizeWidth,
  scaleNorthWest,
  scaleNorthEast,
  scaleSouthEast,
  scaleSouthWest,
  rotate,
}

class TextHudGeometry {
  const TextHudGeometry({
    required this.position,
    required this.width,
    required this.height,
    required this.fontSize,
    required this.rotation,
  });

  final Offset position;
  final double width;
  final double height;
  final double fontSize;
  final double rotation;

  Offset get center => position + Offset(width / 2, height / 2);

  Offset get axisX => Offset(math.cos(rotation), math.sin(rotation));

  Offset get axisY => Offset(-math.sin(rotation), math.cos(rotation));

  Offset pointAt(double xFactor, double yFactor) {
    final local = Offset(width * xFactor, height * yFactor);
    final relative = local - Offset(width / 2, height / 2);
    return center + _rotate(relative, rotation);
  }

  TextHudGeometry copyWith({
    Offset? position,
    double? width,
    double? height,
    double? fontSize,
    double? rotation,
  }) {
    return TextHudGeometry(
      position: position ?? this.position,
      width: width ?? this.width,
      height: height ?? this.height,
      fontSize: fontSize ?? this.fontSize,
      rotation: rotation ?? this.rotation,
    );
  }
}

class TextHudEngine {
  TextHudEngine({
    this.minWidth = 72,
    this.maxWidth = 1200,
    this.minFontSize = 8,
    this.maxFontSize = 96,
  });

  final double minWidth;
  final double maxWidth;
  final double minFontSize;
  final double maxFontSize;

  _TextHudGesture? _gesture;
  TextHudGeometry? _lastPreview;

  bool get isActive => _gesture != null;

  TextHudOperation? get operation => _gesture?.operation;

  void begin(
    TextHudOperation operation,
    TextHudGeometry geometry,
    Offset pointer,
  ) {
    _gesture = _TextHudGesture(
      operation: operation,
      initial: geometry,
      pointerStart: pointer,
    );
    _lastPreview = geometry;
  }

  TextHudGeometry update(Offset pointer, {bool shift = false}) {
    final gesture = _gesture;
    if (gesture == null) {
      throw StateError('TextHudEngine.update called without begin');
    }

    final next = switch (gesture.operation) {
      TextHudOperation.translate => _translate(
        gesture.initial,
        gesture.pointerStart,
        pointer,
        shift: shift,
      ),
      TextHudOperation.resizeWidth => _resizeWidth(
        gesture.initial,
        pointer,
      ),
      TextHudOperation.scaleNorthWest ||
      TextHudOperation.scaleNorthEast ||
      TextHudOperation.scaleSouthEast ||
      TextHudOperation.scaleSouthWest => _scale(
        gesture.operation,
        gesture.initial,
        pointer,
      ),
      TextHudOperation.rotate => _rotateGeometry(
        gesture.initial,
        gesture.pointerStart,
        pointer,
        shift: shift,
      ),
    };
    _lastPreview = next;
    return next;
  }

  TextHudGeometry? end() {
    final result = _lastPreview;
    _gesture = null;
    _lastPreview = null;
    return result;
  }

  void cancel() {
    _gesture = null;
    _lastPreview = null;
  }

  TextHudGeometry _translate(
    TextHudGeometry initial,
    Offset start,
    Offset pointer, {
    required bool shift,
  }) {
    var delta = pointer - start;
    if (shift) {
      final local = _rotate(delta, -initial.rotation);
      final locked = local.dx.abs() >= local.dy.abs()
          ? Offset(local.dx, 0)
          : Offset(0, local.dy);
      delta = _rotate(locked, initial.rotation);
    }
    return initial.copyWith(position: initial.position + delta);
  }

  TextHudGeometry _resizeWidth(
    TextHudGeometry initial,
    Offset pointer,
  ) {
    final anchor = initial.pointAt(0, 0.5);
    final projected = _dot(pointer - anchor, initial.axisX);
    final nextWidth = projected.clamp(minWidth, maxWidth).toDouble();
    final center = anchor + initial.axisX * (nextWidth / 2);
    final nextPosition =
        center - Offset(nextWidth / 2, initial.height / 2);
    return initial.copyWith(
      position: nextPosition,
      width: nextWidth,
    );
  }

  TextHudGeometry _scale(
    TextHudOperation operation,
    TextHudGeometry initial,
    Offset pointer,
  ) {
    final points = _scalePoints(operation, initial);
    final anchor = points.anchor;
    final dragged = points.dragged;
    final baseVector = dragged - anchor;
    final denominator = _dot(baseVector, baseVector);
    if (denominator <= 1e-9) {
      return initial;
    }

    var scale = _dot(pointer - anchor, baseVector) / denominator;
    final minScale = math.max(
      minWidth / initial.width,
      minFontSize / initial.fontSize,
    );
    final maxScale = math.min(
      maxWidth / initial.width,
      maxFontSize / initial.fontSize,
    );
    scale = scale.clamp(minScale, maxScale).toDouble();

    final nextWidth = initial.width * scale;
    final nextHeight = initial.height * scale;
    final nextFontSize = initial.fontSize * scale;
    final center = anchor + baseVector * (scale / 2);
    final nextPosition =
        center - Offset(nextWidth / 2, nextHeight / 2);

    return initial.copyWith(
      position: nextPosition,
      width: nextWidth,
      height: nextHeight,
      fontSize: nextFontSize,
    );
  }

  TextHudGeometry _rotateGeometry(
    TextHudGeometry initial,
    Offset start,
    Offset pointer, {
    required bool shift,
  }) {
    final center = initial.center;
    final startVector = start - center;
    final currentVector = pointer - center;
    if (startVector.distanceSquared <= 1e-9 ||
        currentVector.distanceSquared <= 1e-9) {
      return initial;
    }

    final startAngle = math.atan2(startVector.dy, startVector.dx);
    final currentAngle = math.atan2(currentVector.dy, currentVector.dx);
    var rotation = initial.rotation + currentAngle - startAngle;
    if (shift) {
      const snap = math.pi / 12;
      rotation = (rotation / snap).round() * snap;
    }
    return initial.copyWith(rotation: _normalizeAngle(rotation));
  }

  _ScalePoints _scalePoints(
    TextHudOperation operation,
    TextHudGeometry geometry,
  ) {
    return switch (operation) {
      TextHudOperation.scaleNorthWest => _ScalePoints(
        anchor: geometry.pointAt(1, 1),
        dragged: geometry.pointAt(0, 0),
      ),
      TextHudOperation.scaleNorthEast => _ScalePoints(
        anchor: geometry.pointAt(0, 1),
        dragged: geometry.pointAt(1, 0),
      ),
      TextHudOperation.scaleSouthEast => _ScalePoints(
        anchor: geometry.pointAt(0, 0),
        dragged: geometry.pointAt(1, 1),
      ),
      TextHudOperation.scaleSouthWest => _ScalePoints(
        anchor: geometry.pointAt(1, 0),
        dragged: geometry.pointAt(0, 1),
      ),
      _ => throw ArgumentError.value(operation, 'operation'),
    };
  }
}

class _TextHudGesture {
  const _TextHudGesture({
    required this.operation,
    required this.initial,
    required this.pointerStart,
  });

  final TextHudOperation operation;
  final TextHudGeometry initial;
  final Offset pointerStart;
}

class _ScalePoints {
  const _ScalePoints({
    required this.anchor,
    required this.dragged,
  });

  final Offset anchor;
  final Offset dragged;
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

double _normalizeAngle(double angle) {
  while (angle <= -math.pi) {
    angle += math.pi * 2;
  }
  while (angle > math.pi) {
    angle -= math.pi * 2;
  }
  return angle;
}
