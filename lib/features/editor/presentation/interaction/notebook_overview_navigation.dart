import 'dart:math' as math;
import 'dart:ui';

/// Converts minimap taps into document-space navigation targets.
class NotebookOverviewNavigation {
  static Offset documentPoint({
    required Offset mapPoint,
    required double mapScale,
    double mapScrollOffset = 0,
    required Size documentSize,
  }) {
    if (mapScale <= 0) {
      return Offset.zero;
    }
    return Offset(
      (mapPoint.dx / mapScale).clamp(0.0, documentSize.width).toDouble(),
      ((mapPoint.dy + mapScrollOffset) / mapScale)
          .clamp(0.0, documentSize.height)
          .toDouble(),
    );
  }

  static NotebookOverviewTarget viewportTarget({
    required Offset documentPoint,
    required Size viewportSize,
    required double effectiveScale,
    required double maxScrollOffset,
    double topPadding = 0,
  }) {
    final scrollOffset =
        (documentPoint.dy * effectiveScale +
                topPadding -
                viewportSize.height / 2)
            .clamp(0.0, math.max(0.0, maxScrollOffset))
            .toDouble();
    final pan = Offset(
      viewportSize.width / 2 - documentPoint.dx * effectiveScale,
      scrollOffset +
          viewportSize.height / 2 -
          topPadding -
          documentPoint.dy * effectiveScale,
    );
    return NotebookOverviewTarget(scrollOffset: scrollOffset, pan: pan);
  }
}

class NotebookOverviewTarget {
  const NotebookOverviewTarget({
    required this.scrollOffset,
    required this.pan,
  });

  final double scrollOffset;
  final Offset pan;
}
