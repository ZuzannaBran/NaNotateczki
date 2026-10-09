import 'dart:math' as math;
import 'dart:ui';

import 'ink_stroke.dart';

const double _cellSize = 128.0;
const int _maxCellsPerStroke = 256;
const int _maxCellsPerQuery = 4096;

final Expando<InkSpatialIndex> _indexCache = Expando<InkSpatialIndex>(
  'inkSpatialIndex',
);

InkSpatialIndex inkSpatialIndexFor(List<InkStroke> strokes) {
  final cached = _indexCache[strokes];
  if (cached != null) {
    return cached;
  }
  final index = InkSpatialIndex(strokes);
  _indexCache[strokes] = index;
  return index;
}

class InkSpatialIndex {
  InkSpatialIndex(this.strokes) {
    for (var index = 0; index < strokes.length; index++) {
      final bounds = _strokeBounds(strokes[index]);
      if (bounds == null) {
        continue;
      }
      final range = _CellRange.fromRect(bounds);
      if (range.cellCount > _maxCellsPerStroke) {
        _overflowIndices.add(index);
        continue;
      }
      for (var x = range.minX; x <= range.maxX; x++) {
        final column = _cells.putIfAbsent(x, () => <int, List<int>>{});
        for (var y = range.minY; y <= range.maxY; y++) {
          column.putIfAbsent(y, () => <int>[]).add(index);
        }
      }
    }
  }

  final List<InkStroke> strokes;
  final Map<int, Map<int, List<int>>> _cells = <int, Map<int, List<int>>>{};
  final List<int> _overflowIndices = <int>[];

  List<InkStroke> query(Rect bounds) {
    if (bounds.isEmpty || strokes.isEmpty) {
      return const <InkStroke>[];
    }
    final range = _CellRange.fromRect(bounds);
    if (range.cellCount > _maxCellsPerQuery) {
      return strokes;
    }
    final indices = <int>{..._overflowIndices};
    for (var x = range.minX; x <= range.maxX; x++) {
      final column = _cells[x];
      if (column == null) {
        continue;
      }
      for (var y = range.minY; y <= range.maxY; y++) {
        final cell = column[y];
        if (cell != null) {
          indices.addAll(cell);
        }
      }
    }
    final orderedIndices = indices.toList()..sort();
    return [for (final index in orderedIndices) strokes[index]];
  }

  List<InkStroke> queryPoint(Offset point, double radius) {
    return query(Rect.fromCircle(center: point, radius: radius));
  }
}

class _CellRange {
  const _CellRange({
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  factory _CellRange.fromRect(Rect rect) {
    return _CellRange(
      minX: (rect.left / _cellSize).floor(),
      maxX: (rect.right / _cellSize).floor(),
      minY: (rect.top / _cellSize).floor(),
      maxY: (rect.bottom / _cellSize).floor(),
    );
  }

  final int minX;
  final int maxX;
  final int minY;
  final int maxY;

  int get cellCount => (maxX - minX + 1) * (maxY - minY + 1);
}

Rect? _strokeBounds(InkStroke stroke) {
  if (stroke.points.isEmpty) {
    return null;
  }
  var minX = stroke.points.first.dx;
  var minY = stroke.points.first.dy;
  var maxX = minX;
  var maxY = minY;
  for (var index = 1; index < stroke.points.length; index++) {
    final point = stroke.points[index];
    minX = math.min(minX, point.dx);
    minY = math.min(minY, point.dy);
    maxX = math.max(maxX, point.dx);
    maxY = math.max(maxY, point.dy);
  }
  return Rect.fromLTRB(
    minX,
    minY,
    maxX,
    maxY,
  ).inflate(math.max(1.0, stroke.width * 0.5));
}
