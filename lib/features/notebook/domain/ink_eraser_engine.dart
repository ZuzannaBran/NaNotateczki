import 'dart:math';
import 'dart:ui';

import 'drawing_tool.dart';
import 'ink_spatial_index.dart';
import 'ink_stroke.dart';

typedef InkStrokeHitTest =
    bool Function(InkStroke stroke, Offset point, double radius);

class LegacyEraserFlattenResult {
  const LegacyEraserFlattenResult({
    required this.strokes,
    required this.changed,
  });

  final List<InkStroke> strokes;
  final bool changed;
}

class InkBrushEraseResult {
  const InkBrushEraseResult({
    required this.strokes,
    required this.changed,
  });

  final List<InkStroke> strokes;
  final bool changed;
}

/// Shared destructive eraser logic used by notebook and board canvases.
///
/// New eraser gestures delete ink strokes from the model. Legacy eraser
/// strokes are supported only for one-time flattening of older documents.
class InkEraserEngine {
  const InkEraserEngine._();

  static void collectPointHits({
    required List<InkStroke> strokes,
    required Offset point,
    required double radius,
    required Set<String> into,
    InkStrokeHitTest? hitTest,
  }) {
    if (radius <= 0 || strokes.isEmpty) {
      return;
    }
    final test = hitTest ?? _strokeTouchesCircle;
    final candidates = inkSpatialIndexFor(
      strokes,
    ).queryPoint(point, radius);
    for (final stroke in candidates) {
      if (into.contains(stroke.id) || !_canErase(stroke)) {
        continue;
      }
      if (test(stroke, point, radius)) {
        into.add(stroke.id);
      }
    }
  }

  static InkBrushEraseResult eraseBrushParts({
    required List<InkStroke> strokes,
    required List<Offset> path,
    required double radius,
    required String Function() createId,
  }) {
    if (strokes.isEmpty || path.isEmpty || radius <= 0) {
      return InkBrushEraseResult(strokes: strokes, changed: false);
    }

    final candidateIds = inkSpatialIndexFor(strokes)
        .query(_pointsBounds(path).inflate(radius))
        .map((stroke) => stroke.id)
        .toSet();
    final next = <InkStroke>[];
    var changed = false;
    for (final stroke in strokes) {
      if (!candidateIds.contains(stroke.id) || !_canErase(stroke)) {
        next.add(stroke);
        continue;
      }
      final parts = _splitStrokeForBrush(
        stroke,
        path,
        radius,
        createId,
      );
      if (parts.length == 1 && identical(parts.single, stroke)) {
        next.add(stroke);
        continue;
      }
      changed = true;
      next.addAll(parts);
    }
    return InkBrushEraseResult(strokes: next, changed: changed);
  }

  static Set<String> areaHits({
    required List<InkStroke> strokes,
    required List<Offset> polygon,
  }) {
    if (polygon.length < 3 || strokes.isEmpty) {
      return <String>{};
    }
    final bounds = _pointsBounds(polygon);
    final candidates = inkSpatialIndexFor(strokes).query(bounds);
    return <String>{
      for (final stroke in candidates)
        if (_canErase(stroke) && _strokeTouchesPolygon(stroke, polygon))
          stroke.id,
    };
  }

  static LegacyEraserFlattenResult flattenLegacyErasers(
    List<InkStroke> strokes,
  ) {
    if (!strokes.any((stroke) => stroke.tool.isEraser)) {
      return LegacyEraserFlattenResult(strokes: strokes, changed: false);
    }

    var fragmentIndex = 0;
    final flattened = <InkStroke>[];
    for (final stroke in strokes) {
      if (stroke.tool == DrawingTool.eraserBrush) {
        final next = _applyLegacyBrush(
          flattened,
          stroke,
          () => '${stroke.id}_legacy_${fragmentIndex++}',
        );
        flattened
          ..clear()
          ..addAll(next);
        continue;
      }
      if (stroke.tool == DrawingTool.eraserArea) {
        final next = _applyLegacyArea(
          flattened,
          stroke,
          () => '${stroke.id}_legacy_${fragmentIndex++}',
        );
        flattened
          ..clear()
          ..addAll(next);
        continue;
      }
      if (stroke.tool != DrawingTool.eraserStroke) {
        flattened.add(stroke);
      }
    }
    return LegacyEraserFlattenResult(strokes: flattened, changed: true);
  }

  static bool _strokeTouchesCircle(
    InkStroke stroke,
    Offset point,
    double radius,
  ) {
    final points = stroke.points;
    if (points.isEmpty) {
      return false;
    }
    final radiusSquared = radius * radius;
    if (points.length == 1) {
      return (points.first.toOffset() - point).distanceSquared <=
          radiusSquared;
    }
    for (var i = 0; i < points.length - 1; i++) {
      if (_distanceSquaredToSegment(
            point,
            points[i].toOffset(),
            points[i + 1].toOffset(),
          ) <=
          radiusSquared) {
        return true;
      }
    }
    return false;
  }

  static bool _strokeTouchesPolygon(
    InkStroke stroke,
    List<Offset> polygon,
  ) {
    final points = stroke.points;
    if (points.isEmpty) {
      return false;
    }
    if (points.any((point) => _pointInPolygon(point.toOffset(), polygon))) {
      return true;
    }
    for (var i = 0; i < points.length - 1; i++) {
      if (_segmentIntersectsPolygon(
        points[i].toOffset(),
        points[i + 1].toOffset(),
        polygon,
      )) {
        return true;
      }
    }
    return false;
  }

  static List<InkStroke> _splitStrokeForBrush(
    InkStroke stroke,
    List<Offset> path,
    double radius,
    String Function() createId,
  ) {
    if (!_canErase(stroke) || stroke.points.isEmpty) {
      return [stroke];
    }

    final eraseRadius = radius + stroke.width * 0.5;
    final eraseRadiusSquared = eraseRadius * eraseRadius;
    if (stroke.points.length == 1) {
      return _distanceSquaredToPolyline(
                stroke.points.first.toOffset(),
                path,
              ) <=
              eraseRadiusSquared
          ? <InkStroke>[]
          : [stroke];
    }

    final sampleStep = max(1.0, min(3.0, eraseRadius * 0.5));
    final sampled = <InkPoint>[stroke.points.first];
    for (var index = 1; index < stroke.points.length; index++) {
      final start = stroke.points[index - 1];
      final end = stroke.points[index];
      final startOffset = start.toOffset();
      final endOffset = end.toOffset();
      final distance = (endOffset - startOffset).distance;
      final steps = max(1, min(1024, (distance / sampleStep).ceil()));
      for (var step = 1; step <= steps; step++) {
        final t = step / steps;
        sampled.add(
          InkPoint(
            dx: start.dx + (end.dx - start.dx) * t,
            dy: start.dy + (end.dy - start.dy) * t,
            pressure:
                start.pressure + (end.pressure - start.pressure) * t,
          ),
        );
      }
    }

    final removed = [
      for (final point in sampled)
        _distanceSquaredToPolyline(point.toOffset(), path) <=
            eraseRadiusSquared,
    ];
    if (!removed.contains(true)) {
      return [stroke];
    }

    final parts = <InkStroke>[];
    var run = <InkPoint>[];
    void flushRun() {
      if (run.length >= 2) {
        parts.add(
          stroke.copyWith(
            id: createId(),
            points: List<InkPoint>.from(run),
          ),
        );
      }
      run = <InkPoint>[];
    }

    for (var index = 0; index < sampled.length; index++) {
      if (removed[index]) {
        flushRun();
      } else {
        run.add(sampled[index]);
      }
    }
    flushRun();
    return parts;
  }

  static List<InkStroke> _applyLegacyBrush(
    List<InkStroke> strokes,
    InkStroke eraser,
    String Function() createId,
  ) {
    final eraserPath = eraser.points.map((point) => point.toOffset()).toList();
    if (eraserPath.isEmpty) {
      return strokes;
    }
    final radius = eraser.width / 2;
    return [
      for (final stroke in strokes)
        ..._splitStroke(
          stroke,
          (point) =>
              _distanceSquaredToPolyline(point, eraserPath) <=
              radius * radius,
          (a, b) =>
              _segmentDistanceSquaredToPolyline(a, b, eraserPath) <=
              radius * radius,
          createId,
        ),
    ];
  }

  static List<InkStroke> _applyLegacyArea(
    List<InkStroke> strokes,
    InkStroke eraser,
    String Function() createId,
  ) {
    final polygon = eraser.points.map((point) => point.toOffset()).toList();
    if (polygon.length < 3) {
      return strokes;
    }
    return [
      for (final stroke in strokes)
        ..._splitStroke(
          stroke,
          (point) => _pointInPolygon(point, polygon),
          (a, b) =>
              _pointInPolygon(a, polygon) ||
              _pointInPolygon(b, polygon) ||
              _segmentIntersectsPolygon(a, b, polygon),
          createId,
        ),
    ];
  }

  static List<InkStroke> _splitStroke(
    InkStroke stroke,
    bool Function(Offset point) removePoint,
    bool Function(Offset a, Offset b) removeSegment,
    String Function() createId,
  ) {
    if (!_canErase(stroke) || stroke.points.length < 2) {
      return [stroke];
    }
    final points = stroke.points;
    final removed = List<bool>.filled(points.length, false);
    for (var i = 0; i < points.length; i++) {
      if (removePoint(points[i].toOffset())) {
        removed[i] = true;
      }
    }
    for (var i = 0; i < points.length - 1; i++) {
      if (removeSegment(points[i].toOffset(), points[i + 1].toOffset())) {
        removed[i] = true;
        removed[i + 1] = true;
      }
    }
    if (!removed.contains(true)) {
      return [stroke];
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

  static bool _canErase(InkStroke stroke) {
    return !stroke.tool.isEraser && stroke.tool != DrawingTool.lasso;
  }

  static Rect _pointsBounds(List<Offset> points) {
    var minX = points.first.dx;
    var minY = points.first.dy;
    var maxX = minX;
    var maxY = minY;
    for (final point in points.skip(1)) {
      minX = min(minX, point.dx);
      minY = min(minY, point.dy);
      maxX = max(maxX, point.dx);
      maxY = max(maxY, point.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static double _distanceSquaredToPolyline(
    Offset point,
    List<Offset> polyline,
  ) {
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

  static double _segmentDistanceSquaredToPolyline(
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
        _segmentDistanceSquared(a, b, polyline[i], polyline[i + 1]),
      );
    }
    return best;
  }

  static double _distanceSquaredToSegment(
    Offset point,
    Offset start,
    Offset end,
  ) {
    final segment = end - start;
    final lengthSquared = segment.distanceSquared;
    if (lengthSquared == 0) {
      return (point - start).distanceSquared;
    }
    final fromStart = point - start;
    final t =
        ((fromStart.dx * segment.dx + fromStart.dy * segment.dy) /
                lengthSquared)
            .clamp(0.0, 1.0);
    final projection = Offset(
      start.dx + segment.dx * t,
      start.dy + segment.dy * t,
    );
    return (point - projection).distanceSquared;
  }

  static double _segmentDistanceSquared(
    Offset a,
    Offset b,
    Offset c,
    Offset d,
  ) {
    if (_segmentsIntersect(a, b, c, d)) {
      return 0;
    }
    return [
      _distanceSquaredToSegment(a, c, d),
      _distanceSquaredToSegment(b, c, d),
      _distanceSquaredToSegment(c, a, b),
      _distanceSquaredToSegment(d, a, b),
    ].reduce(min);
  }

  static bool _pointInPolygon(Offset point, List<Offset> polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i];
      final b = polygon[j];
      final crossesY = (a.dy > point.dy) != (b.dy > point.dy);
      if (!crossesY) {
        continue;
      }
      final x =
          (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx;
      if (point.dx < x) {
        inside = !inside;
      }
    }
    return inside;
  }

  static bool _segmentIntersectsPolygon(
    Offset a,
    Offset b,
    List<Offset> polygon,
  ) {
    for (var i = 0; i < polygon.length; i++) {
      final c = polygon[i];
      final d = polygon[(i + 1) % polygon.length];
      if (_segmentsIntersect(a, b, c, d)) {
        return true;
      }
    }
    return false;
  }

  static bool _segmentsIntersect(
    Offset a,
    Offset b,
    Offset c,
    Offset d,
  ) {
    final o1 = _orientation(a, b, c);
    final o2 = _orientation(a, b, d);
    final o3 = _orientation(c, d, a);
    final o4 = _orientation(c, d, b);
    if (o1 == 0 && _onSegment(a, c, b)) {
      return true;
    }
    if (o2 == 0 && _onSegment(a, d, b)) {
      return true;
    }
    if (o3 == 0 && _onSegment(c, a, d)) {
      return true;
    }
    if (o4 == 0 && _onSegment(c, b, d)) {
      return true;
    }
    return o1 != o2 && o3 != o4;
  }

  static int _orientation(Offset a, Offset b, Offset c) {
    final value =
        (b.dy - a.dy) * (c.dx - b.dx) -
        (b.dx - a.dx) * (c.dy - b.dy);
    if (value.abs() < 0.000001) {
      return 0;
    }
    return value > 0 ? 1 : 2;
  }

  static bool _onSegment(Offset a, Offset b, Offset c) {
    return b.dx <= max(a.dx, c.dx) &&
        b.dx >= min(a.dx, c.dx) &&
        b.dy <= max(a.dy, c.dy) &&
        b.dy >= min(a.dy, c.dy);
  }
}
