import 'package:flutter/material.dart';

import '../../../notebook/domain/notebook.dart';
import '../../../notebook/domain/notebook_kind.dart';

class LibraryItemCard extends StatelessWidget {
  const LibraryItemCard({
    required this.item,
    required this.selected,
    this.compact = false,
    this.textScale = 1.0,
    required this.onTap,
    required this.onDelete,
    super.key,
  });

  final Notebook item;
  final bool selected;
  final bool compact;
  final double textScale;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isBoard = item.kind == NotebookKind.board;
    return ListTile(
      selected: selected,
      dense: compact,
      visualDensity: compact
          ? VisualDensity.compact
          : VisualDensity.standard,
      minLeadingWidth: compact ? 20 : 40,
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 16,
        vertical: compact ? 2 : 4,
      ),
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.08),
      leading: Icon(
        isBoard ? Icons.dashboard_outlined : Icons.menu_book,
        size: compact ? 18 : 24,
      ),
      title: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        style: (Theme.of(context).textTheme.bodyLarge ?? const TextStyle())
            .copyWith(
              fontSize:
                  (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) *
                      textScale,
            ),
        child: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      subtitle: compact
          ? null
          : AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              style: (Theme.of(context).textTheme.bodySmall ??
                      const TextStyle())
                  .copyWith(
                    fontSize:
                        (Theme.of(context).textTheme.bodySmall?.fontSize ??
                                12) *
                            textScale,
                  ),
              child: Text(
                isBoard ? 'Board' : '${item.pages.length} pages',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        onPressed: onDelete,
        tooltip: 'Delete item',
      ),
      onTap: onTap,
    );
  }
}
