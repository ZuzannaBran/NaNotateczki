import 'dart:math';
import 'dart:ui';

import 'drawing_tool.dart';
import 'ink_spatial_index.dart';
import 'ink_stroke.dart';
import 'notebook.dart';
import 'note_page.dart';

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
  const InkBrushEraseResult({required this.strokes, required this.changed});

  final List<InkStroke> strokes;
  final bool changed;
}

/// Shared destructive eraser logic used by notebook and board canvases.
///
/// New eraser gestures delete ink strokes from the model. Legacy eraser
/// strokes are supported only for one-time flattening of older documents.
class InkEraserEngine {
  const InkEraserEngine._();

  static NotePage normalizePage(NotePage page) {
    final result = flattenLegacyErasers(page.inkStrokes);
    return result.changed ? page.copyWith(inkStrokes: result.strokes) : page;
  }

  static Notebook normalizeNotebook(Notebook notebook) {
    var changed = false;
    final pages = <NotePage>[];
    for (final page in notebook.pages) {
      final normalized = normalizePage(page);
      changed = changed || !identical(normalized, page);
      pages.add(normalized);
    }
    return changed ? notebook.copyWith(pages: pages) : notebook;
  }

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
    final candidates = inkSpatialIndexFor(strokes).queryPoint(point, radius);
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
      final parts = _splitStrokeForBrush(stroke, path, radius, createId);
      if (parts.length == 1 && identical(parts.single, stroke)) {
        next.add(stroke);
        continue;
      }
      changed = true;
      next.addAll(parts);
    }
    return InkBrushEraseResult(strokes: next, changed: changed);
  }

  static int scratchInkHitCount({
    required List<InkStroke> strokes,
    required List<InkPoint> gesture,
    required double radius,
  }) {
    if (strokes.isEmpty || gesture.isEmpty || radius <= 0) {
      return 0;
    }
    final gestureOffsets = gesture.map((point) => point.toOffset()).toList();
    final candidates = inkSpatialIndexFor(
      strokes,
    ).query(_pointsBounds(gestureOffsets).inflate(radius));
    var hits = 0;
    for (final stroke in candidates) {
      if (!_canErase(stroke) || stroke.points.length < 2) {
        continue;
      }
      hits += _strokeGestureHitCount(stroke, gestureOffsets, radius);
    }
    return hits;
  }

  static InkBrushEraseResult eraseScratchParts({
    required List<InkStroke> strokes,
    required List<InkPoint> gesture,
    required double radius,
    required String Function() createId,
  }) {
    if (strokes.isEmpty || gesture.isEmpty || radius <= 0) {
      return InkBrushEraseResult(strokes: strokes, changed: false);
    }
    final gestureOffsets = gesture.map((point) => point.toOffset()).toList();
    final candidateIds = inkSpatialIndexFor(strokes)
        .query(_pointsBounds(gestureOffsets).inflate(radius))
        .map((stroke) => stroke.id)
        .toSet();
    final next = <InkStroke>[];
    var changed = false;
    for (final stroke in strokes) {
      if (!candidateIds.contains(stroke.id) ||
          !_canErase(stroke) ||
          stroke.points.length < 2) {
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
    return InkBrushEraseResult(strokes: next, changed: changed);
  }

  /// Removes the polygon-covered portion of each stroke, not its whole ID.
  static InkBrushEraseResult eraseAreaParts({
    required List<InkStroke> strokes,
    required List<Offset> polygon,
    required String Function() createId,
  }) {
    if (strokes.isEmpty || polygon.length < 3) {
      return InkBrushEraseResult(strokes: strokes, changed: false);
    }
    final candidates = inkSpatialIndexFor(strokes)
        .query(_pointsBounds(polygon))
        .map((stroke) => stroke.id)
        .toSet();
    final next = <InkStroke>[];
    var changed = false;
    for (final stroke in strokes) {
      if (!candidates.contains(stroke.id) || !_canErase(stroke)) {
        next.add(stroke);
        continue;
      }
      final fragments = _splitStrokeForArea(stroke, polygon, createId);
      if (fragments.length == 1 && identical(fragments.single, stroke)) {
        next.add(stroke);
      } else {
        changed = true;
        next.addAll(fragments);
      }
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
    final usedIds = strokes.map((stroke) => stroke.id).toSet();
    String nextFragmentId(String eraserId) {
      while (true) {
        final candidate = '${eraserId}_legacy_${fragmentIndex++}';
        if (usedIds.add(candidate)) {
          return candidate;
        }
      }
    }

    final flattened = <InkStroke>[];
    for (final stroke in strokes) {
      if (stroke.tool == DrawingTool.eraserBrush) {
        final next = _applyLegacyBrush(
          flattened,
          stroke,
          () => nextFragmentId(stroke.id),
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
          () => nextFragmentId(stroke.id),
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
      return (points.first.toOffset() - point).distanceSquared <= radiusSquared;
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

  static bool _strokeTouchesPolygon(InkStroke stroke, List<Offset> polygon) {
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

  static List<InkStroke> _splitStrokeForArea(
    InkStroke stroke,
    List<Offset> polygon,
    String Function() createId,
  ) {
    final points = stroke.points;
    if (points.isEmpty) {
      return [stroke];
    }
    if (points.length == 1) {
      return _insideOrOnPolygon(points.single.toOffset(), polygon)
          ? <InkStroke>[]
          : [stroke];
    }

    var changed = false;
    final fragments = <InkStroke>[];
    var run = <InkPoint>[];
    void flush() {
      if (run.length > 1) {
        fragments.add(stroke.copyWith(id: createId(), points: List.of(run)));
      }
      run = <InkPoint>[];
    }

    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      final start = a.toOffset();
      final delta = b.toOffset() - start;
      final lengthSquared = delta.distanceSquared;
      final cuts = <double>[0, 1];
      if (lengthSquared > 0) {
        for (var j = 0; j < polygon.length; j++) {
          final c = polygon[j];
          final d = polygon[(j + 1) % polygon.length];
          final edge = d - c;
          final relative = c - start;
          final denominator = _cross(delta, edge);
          if (denominator.abs() < 1e-10) {
            if (_cross(relative, delta).abs() < 1e-8) {
              for (final p in [c, d]) {
                final projected = p - start;
                final t = (projected.dx * delta.dx +
                        projected.dy * delta.dy) /
                    lengthSquared;
                if (t >= 0 && t <= 1) {
                  cuts.add(t);
                }
              }
            }
            continue;
          }
          final t = _cross(relative, edge) / denominator;
          final u = _cross(relative, delta) / denominator;
          if (t >= 0 && t <= 1 && u >= 0 && u <= 1) {
            cuts.add(t);
          }
        }
      }
      cuts.sort();
      for (var j = 0; j < cuts.length - 1; j++) {
        final from = cuts[j];
        final to = cuts[j + 1];
        if (to - from <= 1e-9) {
          continue;
        }
        if (_insideOrOnPolygon(start + delta * ((from + to) / 2), polygon)) {
          changed = true;
          flush();
          continue;
        }
        InkPoint at(double t) => InkPoint(
          dx: a.dx + (b.dx - a.dx) * t,
          dy: a.dy + (b.dy - a.dy) * t,
          pressure: a.pressure + (b.pressure - a.pressure) * t,
        );

        final first = at(from);
        final last = at(to);
        if (run.isNotEmpty &&
            (run.last.toOffset() - first.toOffset()).distanceSquared > 1e-10) {
          flush();
        }
        if (run.isEmpty) {
          run.add(first);
        }
        if ((run.last.toOffset() - last.toOffset()).distanceSquared > 1e-10) {
          run.add(last);
        }
      }
    }
    if (!changed) {
      return [stroke];
    }
    flush();
    return fragments;
  }

  static bool _insideOrOnPolygon(Offset point, List<Offset> polygon) {
    if (_pointInPolygon(point, polygon)) {
      return true;
    }
    for (var i = 0; i < polygon.length; i++) {
      if (_distanceSquaredToSegment(
            point,
            polygon[i],
            polygon[(i + 1) % polygon.length],
          ) <= 1e-10) {
        return true;
      }
    }
    return false;
  }

  static double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;

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
      return _distanceSquaredToPolyline(stroke.points.first.toOffset(), path) <=
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
            pressure: start.pressure + (end.pressure - start.pressure) * t,
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
          stroke.copyWith(id: createId(), points: List<InkPoint>.from(run)),
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
              _distanceSquaredToPolyline(point, eraserPath) <= radius * radius,
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
    if (!_canErase(stroke) || stroke.points.isEmpty) {
      return [stroke];
    }
    if (stroke.points.length == 1) {
      return removePoint(stroke.points.single.toOffset())
          ? <InkStroke>[]
          : [stroke];
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

  static List<InkStroke>? _splitStrokeAroundGesture(
    InkStroke stroke,
    List<Offset> gesture,
    double radius,
    String Function() createId,
  ) {
    final points = stroke.points;
    final removed = List<bool>.filled(points.length, false);
    final radiusSquared = radius * radius;
    for (var index = 0; index < points.length; index++) {
      if (_distanceSquaredToPolyline(points[index].toOffset(), gesture) <=
          radiusSquared) {
        removed[index] = true;
      }
    }
    for (var index = 0; index < points.length - 1; index++) {
      if (_segmentDistanceSquaredToPolyline(
            points[index].toOffset(),
            points[index + 1].toOffset(),
            gesture,
          ) <=
          radiusSquared) {
        removed[index] = true;
        removed[index + 1] = true;
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

    for (var index = 0; index < points.length; index++) {
      if (removed[index]) {
        flushRun();
      } else {
        run.add(points[index]);
      }
    }
    flushRun();
    return parts;
  }

  static int _strokeGestureHitCount(
    InkStroke stroke,
    List<Offset> gesture,
    double radius,
  ) {
    final radiusSquared = radius * radius;
    var hits = 0;
    for (final point in stroke.points) {
      if (_distanceSquaredToPolyline(point.toOffset(), gesture) <=
          radiusSquared) {
        hits++;
      }
    }
    for (var index = 0; index < stroke.points.length - 1; index++) {
      if (_segmentDistanceSquaredToPolyline(
            stroke.points[index].toOffset(),
            stroke.points[index + 1].toOffset(),
            gesture,
          ) <=
          radiusSquared) {
        hits++;
      }
    }
    return hits;
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
      final x = (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx;
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

  static bool _segmentsIntersect(Offset a, Offset b, Offset c, Offset d) {
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
    final value = (b.dy - a.dy) * (c.dx - b.dx) - (b.dx - a.dx) * (c.dy - b.dy);
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
