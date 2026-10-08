import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/editor/presentation/widgets/selection_outline.dart';

void main() {
  test('dashes a line without changing the source path', () {
    final source = Path()
      ..moveTo(0, 0)
      ..lineTo(120, 0);
    final segments = dashedSelectionOutline(source).computeMetrics().toList();

    expect(segments.length, greaterThan(2));
    expect(
      segments.every(
        (segment) => segment.length <= selectionOutlineDashLength + 0.01,
      ),
      isTrue,
    );
    expect(
      segments.fold<double>(0, (length, segment) => length + segment.length),
      lessThan(120),
    );
    expect(source.computeMetrics().single.length, closeTo(120, 0.01));
  });

  test('compensates the dash lengths for the document zoom', () {
    final source = Path()
      ..moveTo(0, 0)
      ..lineTo(120, 0);
    final normal = dashedSelectionOutline(source).computeMetrics().first;
    final zoomed = dashedSelectionOutline(
      source,
      scale: 2,
    ).computeMetrics().first;

    expect(normal.length, closeTo(7, 0.01));
    expect(zoomed.length, closeTo(3.5, 0.01));
  });

  test('renders a closed freeform area within its bounds', () {
    final source = Path()
      ..moveTo(10, 20)
      ..lineTo(70, 20)
      ..lineTo(70, 60)
      ..close();
    final dashed = dashedSelectionOutline(source);

    expect(dashed.computeMetrics().length, greaterThan(3));
    expect(dashed.getBounds().left, greaterThanOrEqualTo(10));
    expect(dashed.getBounds().right, lessThanOrEqualTo(70));
  });

  test('keeps an empty outline empty', () {
    expect(dashedSelectionOutline(Path()).computeMetrics().isEmpty, isTrue);
  });
}
