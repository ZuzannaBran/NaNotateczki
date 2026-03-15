import 'package:flutter/material.dart';

import '../../../notebook/domain/notebook.dart';

class NotebookCard extends StatelessWidget {
  const NotebookCard({
    required this.notebook,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    super.key,
  });

  final Notebook notebook;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.08),
      title: Text(notebook.title),
      subtitle: Text('${notebook.pages.length} pages'),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
        tooltip: 'Delete notebook',
      ),
      onTap: onTap,
    );
  }
}
