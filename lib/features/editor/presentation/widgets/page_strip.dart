import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../notebook/domain/note_page.dart';
import '../../state/editor_controller.dart';

class PageStrip extends StatelessWidget {
  const PageStrip({required this.controller, super.key});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return SizedBox(
          height: 124,
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
                  itemBuilder: (context, index) {
                    final page = controller.pages[index];
                    return _PagePreviewChip(
                      page: page,
                      selected: controller.currentPageIndex == index,
                      onTap: () => controller.setCurrentPage(index),
                    );
                  },
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 10),
                  itemCount: controller.pages.length,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: controller.addPage,
                  tooltip: 'Add page',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PagePreviewChip extends StatelessWidget {
  const _PagePreviewChip({
    required this.page,
    required this.selected,
    required this.onTap,
  });

  final NotePage page;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedBorder = theme.colorScheme.primary;
    final idleBorder = theme.dividerColor.withValues(alpha: 0.75);
    final selectedShadow = theme.colorScheme.primary.withValues(alpha: 0.14);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 112,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? selectedBorder : idleBorder,
              width: selected ? 1.8 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: selectedShadow,
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: CustomPaint(
                    painter: _PagePreviewPainter(page),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              if (page.isBookmarked)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(
                    Icons.bookmark,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PagePreviewPainter extends CustomPainter {
  _PagePreviewPainter(this.page);

  final NotePage page;

  @override
  void paint(Canvas canvas, Size size) {
    final paperPaint = Paint()..color = const Color(0xFFFCFDFF);
    canvas.drawRect(Offset.zero & size, paperPaint);

    final framePaint = Paint()
      ..color = const Color(0xFFE1E5EC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect((Offset.zero & size).deflate(0.5), framePaint);

    final bounds = _contentBounds(page);
    if (bounds == null) {
      _paintPlaceholder(canvas, size);
      return;
    }

    final fittedBounds = bounds.inflate(28);
    final scale = math.min(
      size.width / fittedBounds.width,
      size.height / fittedBounds.height,
    );
    final scaledSize = Size(
      fittedBounds.width * scale,
      fittedBounds.height * scale,
    );
    final origin = Offset(
      (size.width - scaledSize.width) / 2 - (fittedBounds.left * scale),
      (size.height - scaledSize.height) / 2 - (fittedBounds.top * scale),
    );

    Offset toCanvas(Offset point) => Offset(
      point.dx * scale + origin.dx,
      point.dy * scale + origin.dy,
    );

    final imageFill = Paint()..color = const Color(0xFFE6ECF5);
    final imageBorder = Paint()
      ..color = const Color(0xFFB7C2D0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (final block in page.imageBlocks) {
      final topLeft = toCanvas(block.position);
      final rect = Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        block.width * scale,
        block.height * scale,
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2.4));
      canvas.drawRRect(rrect, imageFill);
      canvas.drawRRect(rrect, imageBorder);
    }

    final textPaint = Paint()..color = const Color(0xFF96A2B4);
    for (final block in page.textBlocks) {
      final topLeft = toCanvas(block.position + const Offset(0, 2));
      final lineWidth = (block.width * scale * 0.82).clamp(10.0, size.width * 0.78)
          .toDouble();
      final lineHeight = math.max(1.8, block.fontSize * scale * 0.16);
      final line = RRect.fromRectAndRadius(
        Rect.fromLTWH(topLeft.dx, topLeft.dy, lineWidth, lineHeight),
        const Radius.circular(1.2),
      );
      canvas.drawRRect(line, textPaint);
    }

    for (final stroke in page.inkStrokes) {
      if (stroke.points.isEmpty) {
        continue;
      }
      final strokePaint = Paint()
        ..color = stroke.tool.name == 'highlighter'
            ? stroke.color.withValues(alpha: 0.3)
            : stroke.color.withValues(alpha: 0.92)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = (stroke.width * scale).clamp(0.7, 3.0);

      if (stroke.points.length == 1) {
        final point = toCanvas(stroke.points.first.toOffset());
        canvas.drawCircle(point, strokePaint.strokeWidth / 2, strokePaint);
        continue;
      }

      final path = Path();
      final first = toCanvas(stroke.points.first.toOffset());
      path.moveTo(first.dx, first.dy);
      for (var i = 1; i < stroke.points.length; i++) {
        final point = toCanvas(stroke.points[i].toOffset());
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, strokePaint);
    }
  }

  Rect? _contentBounds(NotePage page) {
    double? minX;
    double? minY;
    double? maxX;
    double? maxY;

    void includePoint(Offset point) {
      minX = minX == null ? point.dx : math.min(minX!, point.dx);
      minY = minY == null ? point.dy : math.min(minY!, point.dy);
      maxX = maxX == null ? point.dx : math.max(maxX!, point.dx);
      maxY = maxY == null ? point.dy : math.max(maxY!, point.dy);
    }

    void includeRect(Rect rect) {
      includePoint(rect.topLeft);
      includePoint(rect.bottomRight);
    }

    for (final stroke in page.inkStrokes) {
      for (final point in stroke.points) {
        includePoint(point.toOffset());
      }
    }

    for (final block in page.textBlocks) {
      final estimatedHeight = math.max(24.0, block.fontSize * 1.9);
      includeRect(
        Rect.fromLTWH(
          block.position.dx,
          block.position.dy,
          math.max(24.0, block.width),
          estimatedHeight,
        ),
      );
    }

    for (final block in page.imageBlocks) {
      includeRect(
        Rect.fromLTWH(
          block.position.dx,
          block.position.dy,
          math.max(12.0, block.width),
          math.max(12.0, block.height),
        ),
      );
    }

    if (minX == null || minY == null || maxX == null || maxY == null) {
      return null;
    }

    final bounds = Rect.fromLTRB(minX!, minY!, maxX!, maxY!);
    final minWidth = math.max(bounds.width, 20.0);
    final minHeight = math.max(bounds.height, 20.0);
    return Rect.fromCenter(
      center: bounds.center,
      width: minWidth,
      height: minHeight,
    );
  }

  void _paintPlaceholder(Canvas canvas, Size size) {
    final guidePaint = Paint()
      ..color = const Color(0xFFD7DEE9)
      ..strokeWidth = 0.9
      ..strokeCap = StrokeCap.round;
    final left = size.width * 0.14;
    final right = size.width * 0.86;
    final top = size.height * 0.28;
    final gap = size.height * 0.19;

    for (var i = 0; i < 3; i++) {
      final y = top + (i * gap);
      canvas.drawLine(Offset(left, y), Offset(right, y), guidePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PagePreviewPainter oldDelegate) {
    return oldDelegate.page != page;
  }
}
