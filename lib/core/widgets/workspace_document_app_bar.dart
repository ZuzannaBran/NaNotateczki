import 'package:flutter/material.dart';

import 'app_header_divider.dart';

/// Shared document header for notebooks, boards and planners.
class WorkspaceDocumentAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const WorkspaceDocumentAppBar({
    required this.title,
    required this.onSettings,
    this.onOpenNavigation,
    this.extraActions = const <Widget>[],
    super.key,
  });

  final String title;
  final VoidCallback onSettings;
  final VoidCallback? onOpenNavigation;
  final List<Widget> extraActions;

  @override
  Size get preferredSize =>
      const Size.fromHeight(AppHeaderDivider.toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final titleSpacing =
        onOpenNavigation == null || MediaQuery.sizeOf(context).width >= 600
        ? 44.0
        : null;
    return AppBar(
      toolbarHeight: AppHeaderDivider.toolbarHeight,
      automaticallyImplyLeading: false,
      titleSpacing: titleSpacing,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      leading: onOpenNavigation == null
          ? null
          : IconButton(
              key: const ValueKey('mobile-navigation-open'),
              tooltip: 'Open navigation',
              icon: const Icon(Icons.menu_rounded),
              onPressed: onOpenNavigation,
            ),
      title: Text(
        title,
        key: const ValueKey('workspace-document-title'),
        style: AppHeaderDivider.titleStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        ...extraActions,
        IconButton(
          key: const ValueKey('workspace-document-settings'),
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Settings',
          onPressed: onSettings,
        ),
      ],
    );
  }
}
