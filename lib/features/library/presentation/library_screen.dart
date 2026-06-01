import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/empty_state.dart';
import '../../board/presentation/board_screen.dart';
import '../../editor/state/editor_controller.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../notebook/presentation/notebook_screen.dart';
import 'library_controller.dart';
import 'widgets/library_item_card.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const double _wideBreakpoint = 1100;
  static const double _folderPaneMinWidth = 56;
  static const double _folderPaneMaxWidth = 420;
  static const double _itemsPaneMinWidth = 170;
  static const double _itemsPaneMaxWidth = 520;
  static const double _resizeHandleWidth = 12;

  bool _showLeftNavigation = true;
  double _folderPaneWidth = 220;
  double _itemsPaneWidth = 320;

  double _textScaleForPane({
    required double width,
    required double minWidth,
    required double maxWidth,
    double minScale = 0.72,
    double maxScale = 1.0,
  }) {
    final normalized = ((width - minWidth) / (maxWidth - minWidth)).clamp(
      0.0,
      1.0,
    );
    return minScale + (maxScale - minScale) * normalized;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<LibraryController>().initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LibraryController>();
    final selectedItem = controller.selectedItem();

    return Scaffold(
      body: Column(
        children: [
          if (controller.shouldShowResetBanner)
            MaterialBanner(
              backgroundColor: Colors.amber.shade100,
              content: Text(
                controller.autoRestoreCount > 0
                    ? 'Baza została zresetowana po zmianie struktury. Przywrócono ${controller.autoRestoreCount} notatek z lokalnego backupu.'
                    : 'Baza została zresetowana po zmianie struktury danych. Lokalny backup nie był dostępny.',
              ),
              actions: [
                TextButton(
                  onPressed: controller.dismissResetBanner,
                  child: const Text('OK'),
                ),
              ],
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= _wideBreakpoint;
                if (isWide) {
                  final maxSideWidth = math.max(
                    _folderPaneMinWidth + _itemsPaneMinWidth,
                    constraints.maxWidth - 320,
                  );
                  var folderWidth = _folderPaneWidth
                      .clamp(_folderPaneMinWidth, _folderPaneMaxWidth)
                      .toDouble();
                  var itemsWidth = _itemsPaneWidth
                      .clamp(_itemsPaneMinWidth, _itemsPaneMaxWidth)
                      .toDouble();
                  final totalWidth = folderWidth + itemsWidth;
                  if (totalWidth > maxSideWidth) {
                    final overflow = totalWidth - maxSideWidth;
                    final shrinkFromItems = math.min(
                      overflow,
                      itemsWidth - _itemsPaneMinWidth,
                    );
                    itemsWidth -= shrinkFromItems;
                    final restOverflow = overflow - shrinkFromItems;
                    if (restOverflow > 0) {
                      folderWidth = math.max(
                        _folderPaneMinWidth,
                        folderWidth - restOverflow,
                      );
                    }
                  }

                  final folderIconOnly = folderWidth < 165;
                  final itemsCompact = itemsWidth < 260;
                  final itemsTextScale = _textScaleForPane(
                    width: itemsWidth,
                    minWidth: _itemsPaneMinWidth,
                    maxWidth: 360,
                    minScale: 0.72,
                  );
                  final expandedLeftZoneWidth =
                      folderWidth +
                      _resizeHandleWidth +
                      itemsWidth +
                      _resizeHandleWidth;
                  final leftZoneWidth = _showLeftNavigation
                      ? expandedLeftZoneWidth
                      : 0.0;

                  return Stack(
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: leftZoneWidth,
                            child: _showLeftNavigation
                                ? Row(
                                    children: [
                                      SizedBox(
                                        width: folderWidth,
                                        child: _FolderListPane(
                                          controller: controller,
                                          onSelect: controller.selectFolder,
                                          iconOnly: folderIconOnly,
                                        ),
                                      ),
                                      _PaneResizeHandle(
                                        onDragDelta: (delta) {
                                          setState(() {
                                            _folderPaneWidth =
                                                (_folderPaneWidth + delta)
                                                    .clamp(
                                                      _folderPaneMinWidth,
                                                      _folderPaneMaxWidth,
                                                    )
                                                    .toDouble();
                                          });
                                        },
                                      ),
                                      SizedBox(
                                        width: itemsWidth,
                                        child: _LibraryItemsPane(
                                          controller: controller,
                                          onOpen: (item) =>
                                              controller.selectItem(item.uid),
                                          compact: itemsCompact,
                                          textScale: itemsTextScale,
                                        ),
                                      ),
                                      _PaneResizeHandle(
                                        onDragDelta: (delta) {
                                          setState(() {
                                            _itemsPaneWidth =
                                                (_itemsPaneWidth + delta)
                                                    .clamp(
                                                      _itemsPaneMinWidth,
                                                      _itemsPaneMaxWidth,
                                                    )
                                                    .toDouble();
                                          });
                                        },
                                      ),
                                    ],
                                  )
                                : const SizedBox.shrink(),
                          ),
                          Expanded(
                            child: _LibraryWorkspace(item: selectedItem),
                          ),
                        ],
                      ),
                      Positioned(
                        left: math.max(0.0, leftZoneWidth - 1),
                        top: 0,
                        child: _LeftZoneToggleTab(
                          expanded: _showLeftNavigation,
                          onPressed: _toggleLeftNavigation,
                        ),
                      ),
                    ],
                  );
                }

                return Column(
                  children: [
                    if (_showLeftNavigation) ...[
                      _FolderChipBar(
                        controller: controller,
                        onSelect: controller.selectFolder,
                      ),
                      const Divider(height: 1),
                    ],
                    Expanded(
                      child: _LibraryItemsPane(
                        controller: controller,
                        compact: false,
                        textScale: 1.0,
                        onOpen: (item) {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _LibraryRoute(item: item),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _toggleLeftNavigation() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _showLeftNavigation = !_showLeftNavigation;
    });
  }

  Future<void> _promptNewFolder(LibraryController controller) async {
    final textController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New folder'),
          content: TextField(
            controller: textController,
            decoration: const InputDecoration(hintText: 'Folder name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(textController.text),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    if (result == null) {
      return;
    }
    await controller.createFolder(result);
  }

  Future<void> _promptRenameFolder(
    LibraryController controller,
    String folder,
  ) async {
    final textController = TextEditingController(text: folder);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename folder'),
          content: TextField(
            controller: textController,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Folder name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(textController.text),
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );

    if (result == null) {
      return;
    }
    await controller.renameFolder(folder, result);
  }

  Future<void> _confirmDeleteFolder(
    LibraryController controller,
    String folder,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete folder?'),
          content: const Text(
            'This will delete the folder and all items inside it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (result != true) {
      return;
    }
    await controller.deleteFolder(folder);
  }
}

enum _FolderAction { rename, delete }

class _FolderListPane extends StatelessWidget {
  const _FolderListPane({
    required this.controller,
    required this.onSelect,
    this.iconOnly = false,
  });

  final LibraryController controller;
  final ValueChanged<String> onSelect;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final selectedColor = colorScheme.primary.withValues(alpha: 0.08);
    final folders = controller.folderNames;

    if (iconOnly) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          SizedBox(
            height: 64,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: IconButton(
                  tooltip: 'New folder',
                  icon: const Icon(Icons.add),
                  onPressed: () => context
                      .findAncestorStateOfType<_LibraryScreenState>()
                      ?._promptNewFolder(controller),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          for (var index = 0; index < folders.length; index++) ...[
            if (index > 0) const Divider(height: 1),
            Tooltip(
              message: folders[index],
              waitDuration: const Duration(milliseconds: 350),
              child: ListTile(
                contentPadding: const EdgeInsets.only(left: 16, right: 2),
                title: Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(
                    folders[index] == controller.selectedFolder
                        ? Icons.folder
                        : Icons.folder_outlined,
                    size: 20,
                  ),
                ),
                selected: folders[index] == controller.selectedFolder,
                selectedColor: colorScheme.primary,
                selectedTileColor: selectedColor,
                onTap: () => onSelect(folders[index]),
              ),
            ),
          ],
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Folders',
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.add),
                onPressed: () => context
                    .findAncestorStateOfType<_LibraryScreenState>()
                    ?._promptNewFolder(controller),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        for (var index = 0; index < folders.length; index++) ...[
          if (index > 0) const Divider(height: 1),
          ListTile(
            contentPadding: const EdgeInsets.only(left: 16, right: 2),
            title: Text(
              folders[index],
              style: Theme.of(context).textTheme.bodyLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: folders[index] == controller.selectedFolder,
            selectedColor: colorScheme.primary,
            selectedTileColor: selectedColor,
            trailing: PopupMenuButton<_FolderAction>(
              tooltip: 'Folder actions',
              icon: const Icon(Icons.more_vert),
              padding: EdgeInsets.zero,
              onSelected: (action) {
                final state = context
                    .findAncestorStateOfType<_LibraryScreenState>();
                if (action == _FolderAction.rename) {
                  state?._promptRenameFolder(controller, folders[index]);
                } else {
                  state?._confirmDeleteFolder(controller, folders[index]);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _FolderAction.rename,
                  child: ListTile(
                    leading: Icon(Icons.drive_file_rename_outline),
                    title: Text('Rename'),
                  ),
                ),
                PopupMenuItem(
                  value: _FolderAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('Delete'),
                  ),
                ),
              ],
            ),
            onTap: () => onSelect(folders[index]),
          ),
        ],
      ],
    );
  }
}

class _FolderChipBar extends StatelessWidget {
  const _FolderChipBar({required this.controller, required this.onSelect});

  final LibraryController controller;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            tooltip: 'New folder',
            icon: const Icon(Icons.add),
            onPressed: () => context
                .findAncestorStateOfType<_LibraryScreenState>()
                ?._promptNewFolder(controller),
          ),
          const SizedBox(width: 8),
          for (final folder in controller.folderNames)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChoiceChip(
                    label: Text(folder),
                    selected: folder == controller.selectedFolder,
                    selectedColor: colorScheme.primary.withValues(alpha: 0.08),
                    labelStyle: folder == controller.selectedFolder
                        ? TextStyle(color: colorScheme.primary)
                        : null,
                    onSelected: (_) => onSelect(folder),
                  ),
                  PopupMenuButton<_FolderAction>(
                    tooltip: 'Folder actions',
                    icon: const Icon(Icons.more_vert),
                    onSelected: (action) {
                      final state = context
                          .findAncestorStateOfType<_LibraryScreenState>();
                      if (action == _FolderAction.rename) {
                        state?._promptRenameFolder(controller, folder);
                      } else {
                        state?._confirmDeleteFolder(controller, folder);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _FolderAction.rename,
                        child: Text('Rename'),
                      ),
                      PopupMenuItem(
                        value: _FolderAction.delete,
                        child: Text('Delete'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _LibraryItemsPane extends StatelessWidget {
  const _LibraryItemsPane({
    required this.controller,
    required this.onOpen,
    this.compact = false,
    this.textScale = 1.0,
  });

  final LibraryController controller;
  final ValueChanged<Notebook> onOpen;
  final bool compact;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    if (controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.items.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No items yet',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Create a notebook or board to get started.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  ElevatedButton.icon(
                    onPressed: controller.createNotebook,
                    icon: const Icon(Icons.menu_book),
                    label: const Text('New notebook'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.createBoard,
                    icon: const Icon(Icons.dashboard_outlined),
                    label: const Text('New board'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (controller.visibleItems.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No items here yet',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Create a notebook or board in this folder.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  ElevatedButton.icon(
                    onPressed: controller.createNotebook,
                    icon: const Icon(Icons.menu_book),
                    label: const Text('New notebook'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.createBoard,
                    icon: const Icon(Icons.dashboard_outlined),
                    label: const Text('New board'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOutCubic,
                  style:
                      (Theme.of(context).textTheme.titleMedium ??
                              const TextStyle())
                          .copyWith(
                            fontSize:
                                (Theme.of(
                                      context,
                                    ).textTheme.titleMedium?.fontSize ??
                                    16) *
                                textScale,
                          ),
                  child: Text(
                    controller.selectedFolder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              PopupMenuButton<_CreateAction>(
                tooltip: 'Create',
                onSelected: (action) {
                  if (action == _CreateAction.notebook) {
                    controller.createNotebook();
                  } else {
                    controller.createBoard();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _CreateAction.notebook,
                    child: Text('New notebook'),
                  ),
                  PopupMenuItem(
                    value: _CreateAction.board,
                    child: Text('New board'),
                  ),
                ],
                child: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: controller.visibleItems.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = controller.visibleItems[index];
              return LibraryItemCard(
                item: item,
                selected: item.uid == controller.selectedItemId,
                compact: compact,
                textScale: textScale,
                onTap: () => onOpen(item),
                onDelete: () => controller.deleteItem(item.uid),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LibraryWorkspace extends StatelessWidget {
  const _LibraryWorkspace({required this.item});

  final Notebook? item;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LibraryController>();
    if (controller.isLoadingSelectedItem) {
      return const Center(child: CircularProgressIndicator());
    }
    if (item == null) {
      return const EmptyState(
        title: 'Pick an item',
        message: 'Select a notebook or board from the list.',
      );
    }

    final repository = context.read<NotebookRepository>();
    final isBoard = item!.kind == NotebookKind.board;
    return ChangeNotifierProvider(
      key: ValueKey(item!.uid),
      create: (_) => EditorController(repository: repository, notebook: item!),
      child: isBoard ? const BoardScreen() : const NotebookScreen(),
    );
  }
}

class _LibraryRoute extends StatelessWidget {
  const _LibraryRoute({required this.item});

  final Notebook item;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<NotebookRepository>();
    return FutureBuilder<Notebook?>(
      future: repository.getNotebook(item.uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final resolved = snapshot.data ?? item;
        final isBoard = resolved.kind == NotebookKind.board;
        return ChangeNotifierProvider(
          create: (_) =>
              EditorController(repository: repository, notebook: resolved),
          child: isBoard ? const BoardScreen() : const NotebookScreen(),
        );
      },
    );
  }
}

enum _CreateAction { notebook, board }

class _PaneResizeHandle extends StatelessWidget {
  const _PaneResizeHandle({required this.onDragDelta});

  final ValueChanged<double> onDragDelta;

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).dividerColor;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDragDelta(details.delta.dx),
        child: SizedBox(
          width: _LibraryScreenState._resizeHandleWidth,
          child: Center(child: Container(width: 1, color: dividerColor)),
        ),
      ),
    );
  }
}

class _LeftZoneToggleTab extends StatelessWidget {
  const _LeftZoneToggleTab({required this.expanded, required this.onPressed});

  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 3,
      shadowColor: Colors.black26,
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(12),
        bottomRight: Radius.circular(12),
      ),
      child: InkWell(
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 44,
          child: Icon(
            expanded ? Icons.chevron_left : Icons.chevron_right,
            size: 20,
          ),
        ),
      ),
    );
  }
}
