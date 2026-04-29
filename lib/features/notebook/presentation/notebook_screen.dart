import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/empty_state.dart';
import '../../editor/presentation/editor_screen.dart';
import '../../editor/state/editor_controller.dart';

class NotebookScreen extends StatelessWidget {
  const NotebookScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();

    if (controller.pages.isEmpty) {
      return const EmptyState(
        title: 'Empty notebook',
        message: 'Add a page to start writing.',
      );
    }

    return const _PagesView();
  }
}

class _PagesView extends StatelessWidget {
  const _PagesView();

  @override
  Widget build(BuildContext context) {
    return const EditorScreen();
  }
}
