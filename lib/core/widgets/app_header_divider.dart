import 'package:flutter/material.dart';

/// The same one-pixel divider used below all top app bars.
class AppHeaderDivider extends StatelessWidget implements PreferredSizeWidget {
  const AppHeaderDivider({super.key});

  static const double toolbarHeight = kToolbarHeight;
  static const double thickness = 1;
  static const TextStyle titleStyle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: -0.05,
  );

  static Color colorOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return scheme.outlineVariant;
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
