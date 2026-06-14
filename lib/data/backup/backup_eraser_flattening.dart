import 'dart:math';
import 'dart:ui';

import '../../features/notebook/domain/drawing_tool.dart';
import '../../features/notebook/domain/ink_stroke.dart';
import '../../features/notebook/domain/note_page.dart';
import '../../features/notebook/domain/notebook.dart';

Notebook flattenErasersForBackup(Notebook notebook) {
  return notebook.copyWith(
    pages: notebook.pages.map(_flattenPageErasers).toList(),
  );
}

NotePage _flattenPageErasers(NotePage page) {
  var fragmentIndex = 0;
  final flattened = <InkStroke>[];
  for (final stroke in page.inkStrokes) {
    if (stroke.tool == DrawingTool.eraserBrush) {
      final next = _applyBrushEraser(
        flattened,
        stroke,
        () => '${stroke.id}_backup_${fragmentIndex++}',
      );
      flattened
        ..clear()
        ..addAll(next);
      continue;
    }
    if (stroke.tool == DrawingTool.eraserArea) {
      final next = _applyAreaEraser(
        flattened,
        stroke,
        () => '${stroke.id}_backup_${fragmentIndex++}',
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
  return page.copyWith(inkStrokes: flattened);
}

List<InkStroke> _applyBrushEraser(
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

List<InkStroke> _applyAreaEraser(
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

List<InkStroke> _splitStroke(
  InkStroke stroke,
  bool Function(Offset point) removePoint,
  bool Function(Offset a, Offset b) removeSegment,
  String Function() createId,
) {
  if (!_canFlattenErase(stroke) || stroke.points.length < 2) {
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

bool _canFlattenErase(InkStroke stroke) {
  return stroke.tool != DrawingTool.eraserBrush &&
      stroke.tool != DrawingTool.eraserStroke &&
      stroke.tool != DrawingTool.eraserArea &&
      stroke.tool != DrawingTool.lasso;
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
      _segmentDistanceSquared(a, b, polyline[i], polyline[i + 1]),
    );
  }
  return best;
}

double _distanceSquaredToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.distanceSquared;
  if (lengthSquared == 0) {
    return (p - a).distanceSquared;
  }
  final ap = p - a;
  final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / lengthSquared).clamp(0.0, 1.0);
  final projection = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
  return (p - projection).distanceSquared;
}

double _segmentDistanceSquared(Offset a, Offset b, Offset c, Offset d) {
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

bool _pointInPolygon(Offset point, List<Offset> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    final crossesY = (a.dy > point.dy) != (b.dy > point.dy);
    if (crossesY) {
      final x = (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx;
      if (point.dx < x) {
        inside = !inside;
      }
    }
  }
  return inside;
}

bool _segmentIntersectsPolygon(Offset a, Offset b, List<Offset> polygon) {
  for (var i = 0; i < polygon.length; i++) {
    final c = polygon[i];
    final d = polygon[(i + 1) % polygon.length];
    if (_segmentsIntersect(a, b, c, d)) {
      return true;
    }
  }
  return false;
}

bool _segmentsIntersect(Offset a, Offset b, Offset c, Offset d) {
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

int _orientation(Offset a, Offset b, Offset c) {
  final value = (b.dy - a.dy) * (c.dx - b.dx) - (b.dx - a.dx) * (c.dy - b.dy);
  if (value.abs() < 0.000001) {
    return 0;
  }
  return value > 0 ? 1 : 2;
}

bool _onSegment(Offset a, Offset b, Offset c) {
  return b.dx <= max(a.dx, c.dx) &&
      b.dx >= min(a.dx, c.dx) &&
      b.dy <= max(a.dy, c.dy) &&
      b.dy >= min(a.dy, c.dy);
}
