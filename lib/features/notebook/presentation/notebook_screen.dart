import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/empty_state.dart';
import '../../editor/presentation/editor_screen.dart';
import '../../editor/state/editor_controller.dart';

class NotebookScreen extends StatelessWidget {
  const NotebookScreen({
    super.key,
    this.title,
    this.showToolbar = true,
    this.showCompactTimer = false,
    this.onOpenNavigation,
  });

  final String? title;
  final bool showToolbar;
  final bool showCompactTimer;
  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();

    if (controller.isV2DocumentDeleted) {
      return const EmptyState(
        title: 'Document deleted',
        message: 'This document was deleted on another device.',
      );
    }
    if (controller.pages.isEmpty) {
      return const EmptyState(
        title: 'Empty notebook',
        message: 'Add a page to start writing.',
      );
    }

    return EditorScreen(
      title: title,
      showToolbar: showToolbar,
      showCompactTimer: showCompactTimer,
      onOpenNavigation: onOpenNavigation,
    );
  }
}
