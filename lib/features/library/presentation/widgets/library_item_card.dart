import 'package:flutter/material.dart';

import '../../../notebook/domain/notebook.dart';
import '../../../notebook/domain/notebook_kind.dart';

enum _ItemAction { rename, delete }

class LibraryItemCard extends StatelessWidget {
  const LibraryItemCard({
    required this.item,
    required this.selected,
    this.iconOnly = false,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    super.key,
  });

  final Notebook item;
  final bool selected;
  final bool iconOnly;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isBoard = item.kind == NotebookKind.board;
    const iconSize = 44.0;
    const tileHeight = 72.0;
    if (iconOnly) {
      return SizedBox(
        height: tileHeight,
        child: ListTile(
          selected: selected,
          contentPadding: const EdgeInsets.only(left: 6, right: 2),
          selectedTileColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.08),
          title: Align(
            alignment: Alignment.centerLeft,
            child: _ItemKindIcon(
              icon: isBoard ? Icons.dashboard_outlined : Icons.menu_book,
              size: iconSize,
            ),
          ),
          onTap: onTap,
        ),
      );
    }

    return SizedBox(
      height: tileHeight,
      child: ListTile(
        selected: selected,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        selectedTileColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.08),
        leading: _ItemKindIcon(
          icon: isBoard ? Icons.dashboard_outlined : Icons.menu_book,
          size: iconSize,
        ),
        title: Text(
          item.title,
          style: Theme.of(context).textTheme.bodyLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          isBoard ? 'Board' : '${item.pages.length} pages',
          style: Theme.of(context).textTheme.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<_ItemAction>(
          tooltip: 'Item actions',
          icon: const Icon(Icons.more_vert),
          padding: EdgeInsets.zero,
          onSelected: (action) {
            if (action == _ItemAction.rename) {
              onRename();
            } else {
              onDelete();
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _ItemAction.rename,
              child: ListTile(
                leading: Icon(Icons.drive_file_rename_outline),
                title: Text('Rename'),
              ),
            ),
            PopupMenuItem(
              value: _ItemAction.delete,
              child: ListTile(
                leading: Icon(Icons.delete_outline),
                title: Text('Delete'),
              ),
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _ItemKindIcon extends StatelessWidget {
  const _ItemKindIcon({required this.icon, required this.size});

  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: size * 0.52, color: colorScheme.onSurface),
      ),
    );
  }
}
