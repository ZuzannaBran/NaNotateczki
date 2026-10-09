import 'dart:ui';

import 'package:path_drawing/path_drawing.dart';

import '../../../../core/theme/app_colors.dart';

const double selectionOutlineDashLength = 7.0;
const double selectionOutlineGapLength = 5.0;
const double selectionOutlineWidth = 1.5;

Path dashedSelectionOutline(Path outline, {double scale = 1.0}) {
  final safeScale = scale.isFinite && scale > 0 ? scale : 1.0;
  return dashPath(
    outline,
    dashArray: CircularIntervalList<double>(<double>[
      selectionOutlineDashLength / safeScale,
      selectionOutlineGapLength / safeScale,
    ]),
  );
}

void paintSelectionOutline(Canvas canvas, Path outline, {double scale = 1.0}) {
  final safeScale = scale.isFinite && scale > 0 ? scale : 1.0;
  final paint = Paint()
    ..color = AppColors.inkBlack.withValues(alpha: 0.82)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = selectionOutlineWidth / safeScale;

  canvas.drawPath(dashedSelectionOutline(outline, scale: safeScale), paint);
}
