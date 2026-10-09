import 'package:flutter/widgets.dart';

/// Amplifies finger-driven navigation without modifying scroll-wheel events.
class TouchNavigationScrollPhysics extends ClampingScrollPhysics {
  const TouchNavigationScrollPhysics({
    required this.sensitivity,
    super.parent,
  });

  final double sensitivity;

  @override
  TouchNavigationScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return TouchNavigationScrollPhysics(
      sensitivity: sensitivity,
      parent: buildParent(ancestor),
    );
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    return super.applyPhysicsToUserOffset(position, offset) * sensitivity;
  }

  @override
  double? get dragStartDistanceMotionThreshold =>
      3.5 / sensitivity;
}
