import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../state/page_background.dart';

class PageBackgroundPaint extends StatelessWidget {
  const PageBackgroundPaint({
    required this.settings,
    super.key,
    this.borderRadius = BorderRadius.zero,
    this.origin = Offset.zero,
  });

  final PageBackgroundSettings settings;
  final BorderRadius borderRadius;
  final Offset origin;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: CustomPaint(
        painter: _PageBackgroundPainter(
          settings: settings,
          lineColor: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.55),
          origin: origin,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class PageBackgroundPreview extends StatelessWidget {
  const PageBackgroundPreview({
    required this.settings,
    super.key,
    this.height = 96,
  });

  final PageBackgroundSettings settings;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: AppColors.paper,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: PageBackgroundPaint(
        settings: settings,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

class _PageBackgroundPainter extends CustomPainter {
  const _PageBackgroundPainter({
    required this.settings,
    required this.lineColor,
    required this.origin,
  });

  final PageBackgroundSettings settings;
  final Color lineColor;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    final paperPaint = Paint()..color = AppColors.paper;
    canvas.drawRect(Offset.zero & size, paperPaint);
    if (settings.style == PageBackgroundStyle.blank) {
      return;
    }

    final spacing = settings.spacing.clamp(
      PageBackgroundSettings.minSpacing,
      PageBackgroundSettings.maxSpacing,
    );
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0;

    for (
      var y = _firstLineOffset(origin.dy, spacing);
      y < size.height;
      y += spacing
    ) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    if (settings.style == PageBackgroundStyle.lines) {
      return;
    }
    for (
      var x = _firstLineOffset(origin.dx, spacing);
      x < size.width;
      x += spacing
    ) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  double _firstLineOffset(double originValue, double spacing) {
    final remainder = originValue.remainder(spacing);
    final normalized = remainder < 0 ? remainder + spacing : remainder;
    return normalized == 0 ? spacing : spacing - normalized;
  }

  @override
  bool shouldRepaint(covariant _PageBackgroundPainter oldDelegate) {
    return settings.style != oldDelegate.settings.style ||
        settings.spacing != oldDelegate.settings.spacing ||
        lineColor != oldDelegate.lineColor ||
        origin != oldDelegate.origin;
  }
}
