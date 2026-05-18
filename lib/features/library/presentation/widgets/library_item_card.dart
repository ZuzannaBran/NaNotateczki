import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../notebook/domain/note_page.dart';
import '../../../notebook/domain/notebook.dart';
import '../../../notebook/domain/notebook_kind.dart';

class LibraryItemCard extends StatelessWidget {
  const LibraryItemCard({
    required this.item,
    required this.selected,
    this.compact = false,
    this.textScale = 1.0,
    required this.onTap,
    required this.onDelete,
    super.key,
  });

  final Notebook item;
  final bool selected;
  final bool compact;
  final double textScale;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isBoard = item.kind == NotebookKind.board;
    final previewSize = compact ? 32.0 : 56.0;
    return ListTile(
      selected: selected,
      dense: compact,
      visualDensity: compact
          ? VisualDensity.compact
          : VisualDensity.standard,
      minLeadingWidth: compact ? 20 : 40,
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 16,
        vertical: compact ? 2 : 4,
      ),
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.08),
      leading: compact
          ? Icon(
              isBoard ? Icons.dashboard_outlined : Icons.menu_book,
              size: 18,
            )
          : _NotebookPreview(
              item: item,
              size: previewSize,
              icon: isBoard ? Icons.dashboard_outlined : Icons.menu_book,
            ),
      title: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        style: (Theme.of(context).textTheme.bodyLarge ?? const TextStyle())
            .copyWith(
              fontSize:
                  (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) *
                      textScale,
            ),
        child: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      subtitle: compact
          ? null
          : AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              style: (Theme.of(context).textTheme.bodySmall ??
                      const TextStyle())
                  .copyWith(
                    fontSize:
                        (Theme.of(context).textTheme.bodySmall?.fontSize ??
                                12) *
                            textScale,
                  ),
              child: Text(
                isBoard ? 'Board' : '${item.pages.length} pages',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        onPressed: onDelete,
        tooltip: 'Delete item',
      ),
      onTap: onTap,
    );
  }
}

class _NotebookPreview extends StatelessWidget {
  const _NotebookPreview({
    required this.item,
    required this.size,
    required this.icon,
  });

  final Notebook item;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final borderColor = Theme.of(context).dividerColor;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: borderColor),
              ),
              child: item.pages.isEmpty
                  ? const SizedBox.shrink()
                  : CustomPaint(
                      painter: _NotebookPreviewPainter(item: item),
                    ),
            ),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: Icon(icon, size: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

class _NotebookPreviewPainter extends CustomPainter {
  _NotebookPreviewPainter({required this.item});

  static const double _a4Ratio = 297 / 210;
  static const double _pageWidth = 820.0;
  static const double _pageGap = 26.0;

  final Notebook item;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = _computeBounds(item);
    if (bounds.isEmpty) {
      return;
    }
    final scaleX = size.width / bounds.width;
    final scaleY = size.height / bounds.height;
    final scale = math.min(scaleX, scaleY);
    final offset = Offset(
      (size.width - bounds.width * scale) / 2,
      (size.height - bounds.height * scale) / 2,
    );

    Offset map(Offset point) {
      final dx = (point.dx - bounds.left) * scale + offset.dx;
      final dy = (point.dy - bounds.top) * scale + offset.dy;
      return Offset(dx, dy);
    }

    if (item.kind == NotebookKind.notebook) {
      _paintNotebook(canvas, size, map, scale);
    } else {
      _paintPage(canvas, size, map, scale, item.pages.first, Offset.zero);
    }
  }

  void _paintNotebook(
    Canvas canvas,
    Size size,
    Offset Function(Offset) map,
    double scale,
  ) {
    final pageHeight = _pageWidth * _a4Ratio;
    for (var i = 0; i < item.pages.length; i++) {
      final pageTop = i * (pageHeight + _pageGap);
      final pageRect = Rect.fromLTWH(0, pageTop, _pageWidth, pageHeight);
      final mappedTopLeft = map(pageRect.topLeft);
      final mappedRect = Rect.fromLTWH(
        mappedTopLeft.dx,
        mappedTopLeft.dy,
        pageRect.width * scale,
        pageRect.height * scale,
      );
      canvas.drawRect(mappedRect, Paint()..color = const Color(0xFFFDFEFF));
      canvas.drawRect(
        mappedRect,
        Paint()
          ..color = const Color(0xFFCFD7E4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6,
      );
      _paintPage(
        canvas,
        size,
        map,
        scale,
        item.pages[i],
        Offset(0, pageTop),
      );
    }
  }

  void _paintPage(
    Canvas canvas,
    Size size,
    Offset Function(Offset) map,
    double scale,
    NotePage page,
    Offset pageOrigin,
  ) {
    final imageFill = Paint()..color = const Color(0xFFE6ECF5);
    final imageBorder = Paint()
      ..color = const Color(0xFFB7C2D0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    for (final block in page.imageBlocks) {
      final topLeft = map(block.position + pageOrigin);
      final rect = Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        block.width * scale,
        block.height * scale,
      );
      canvas.drawRect(rect, imageFill);
      canvas.drawRect(rect, imageBorder);
    }

    final textPaint = Paint()..color = const Color(0xFF95A2B4);
    for (final block in page.textBlocks) {
      final topLeft = map(block.position + pageOrigin + const Offset(0, 2));
      final lineWidth = (block.width * scale * 0.8)
          .clamp(4.0, size.width * 0.9)
          .toDouble();
      final lineHeight = math.max(1.0, block.fontSize * scale * 0.18);
      canvas.drawRect(
        Rect.fromLTWH(topLeft.dx, topLeft.dy, lineWidth, lineHeight),
        textPaint,
      );
    }

    for (final stroke in page.inkStrokes) {
      if (stroke.points.isEmpty) {
        continue;
      }
      final paint = Paint()
        ..color = stroke.tool.name == 'highlighter'
            ? stroke.color.withValues(alpha: 0.24)
            : stroke.color.withValues(alpha: 0.88)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = (stroke.width * scale).clamp(0.35, 1.4);

      if (stroke.points.length == 1) {
        final point = map(stroke.points.first.toOffset() + pageOrigin);
        canvas.drawCircle(point, paint.strokeWidth / 2, paint);
        continue;
      }

      final path = Path();
      final first = map(stroke.points.first.toOffset() + pageOrigin);
      path.moveTo(first.dx, first.dy);
      for (var j = 1; j < stroke.points.length; j++) {
        final point = map(stroke.points[j].toOffset() + pageOrigin);
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  Rect _computeBounds(Notebook item) {
    if (item.pages.isEmpty) {
      return Rect.zero;
    }
    if (item.kind == NotebookKind.notebook) {
      final pageHeight = _pageWidth * _a4Ratio;
      final totalHeight =
          (item.pages.length * pageHeight) + ((item.pages.length - 1) * _pageGap);
      return Rect.fromLTWH(0, 0, _pageWidth, totalHeight);
    }

    return _computePageBounds(item.pages.first);
  }

  Rect _computePageBounds(NotePage page) {
    Rect? bounds;

    for (final stroke in page.inkStrokes) {
      if (stroke.points.isEmpty) {
        continue;
      }
      var minX = stroke.points.first.dx;
      var minY = stroke.points.first.dy;
      var maxX = minX;
      var maxY = minY;
      for (final point in stroke.points) {
        minX = math.min(minX, point.dx);
        minY = math.min(minY, point.dy);
        maxX = math.max(maxX, point.dx);
        maxY = math.max(maxY, point.dy);
      }
      final extra = math.max(6.0, stroke.width * 0.5 + 3.0);
      final rect = Rect.fromLTRB(
        minX - extra,
        minY - extra,
        maxX + extra,
        maxY + extra,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    for (final block in page.textBlocks) {
      final estimatedHeight = math.max(36.0, block.fontSize * 2.6);
      final rect = Rect.fromLTWH(
        block.position.dx,
        block.position.dy,
        block.width,
        estimatedHeight,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    for (final block in page.imageBlocks) {
      final rect = Rect.fromLTWH(
        block.position.dx,
        block.position.dy,
        block.width,
        block.height,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    return bounds ?? const Rect.fromLTWH(-200, -200, 400, 400);
  }

  @override
  bool shouldRepaint(covariant _NotebookPreviewPainter oldDelegate) {
    return oldDelegate.item.updatedAt != item.updatedAt ||
        oldDelegate.item.pages.length != item.pages.length;
  }
}
