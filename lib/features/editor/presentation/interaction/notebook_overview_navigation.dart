import 'dart:math' as math;
import 'dart:ui';

/// Maps a minimap tap to a document point and a notebook viewport target.
class NotebookOverviewNavigation {
  static Offset documentPoint({
    required Offset localPoint,
    required double scrollOffset,
    required double mapScale,
    required Size documentSize,
  }) {
    if (mapScale <= 0 || documentSize.isEmpty) {
      return Offset.zero;
    }
    return Offset(
      (localPoint.dx / mapScale).clamp(0.0, documentSize.width).toDouble(),
      ((localPoint.dy + scrollOffset) / mapScale)
          .clamp(0.0, documentSize.height)
          .toDouble(),
    );
  }

  static NotebookOverviewTarget viewportTarget({
    required Offset documentPoint,
    required Size viewportSize,
    required double effectiveScale,
    required double currentPanY,
    required double topPadding,
    required double maxScrollOffset,
  }) {
    final scale = math.max(effectiveScale, 0.001);
    final scrollOffset =
        (documentPoint.dy * scale +
                currentPanY +
                topPadding -
                viewportSize.height / 2)
            .clamp(0.0, math.max(0.0, maxScrollOffset))
            .toDouble();
    final pan = Offset(
      viewportSize.width / 2 - documentPoint.dx * scale,
      scrollOffset +
          viewportSize.height / 2 -
          topPadding -
          documentPoint.dy * scale,
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
