import 'package:flutter/material.dart';

/// The same one-pixel divider used below all top app bars.
class AppHeaderDivider extends StatelessWidget implements PreferredSizeWidget {
  const AppHeaderDivider({super.key});

  static const double thickness = 1;

  static Color colorOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Color.alphaBlend(
      scheme.outlineVariant.withValues(alpha: 0.45),
      scheme.surfaceContainerLowest,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(thickness);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: thickness,
      child: ColoredBox(
        key: const ValueKey('app-header-divider'),
        color: colorOf(context),
      ),
    );
  }
}
