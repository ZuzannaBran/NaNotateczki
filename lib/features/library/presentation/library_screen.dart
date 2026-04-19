import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/empty_state.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../notebook/presentation/notebook_screen.dart';
import '../../editor/state/editor_controller.dart';
import '../../board/presentation/board_screen.dart';
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= _wideBreakpoint;
          if (isWide) {
            final maxSideWidth = math.max(
              _folderPaneMinWidth + _itemsPaneMinWidth,
              constraints.maxWidth - 320,
            );
            var folderWidth = _folderPaneWidth.clamp(
              _folderPaneMinWidth,
              _folderPaneMaxWidth,
            ).toDouble();
            var itemsWidth = _itemsPaneWidth.clamp(
              _itemsPaneMinWidth,
              _itemsPaneMaxWidth,
            ).toDouble();
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

            final folderCompact = folderWidth < 165;
            final folderIconOnly = folderWidth < 96;
            final itemsCompact = itemsWidth < 260;
            final folderTextScale = _textScaleForPane(
              width: folderWidth,
              minWidth: _folderPaneMinWidth,
              maxWidth: 260,
              minScale: 0.68,
            );
            final itemsTextScale = _textScaleForPane(
              width: itemsWidth,
              minWidth: _itemsPaneMinWidth,
              maxWidth: 360,
              minScale: 0.72,
            );
            final expandedLeftZoneWidth =
                folderWidth + _resizeHandleWidth + itemsWidth + _resizeHandleWidth;
            final leftZoneWidth = _showLeftNavigation ? expandedLeftZoneWidth : 0.0;

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
                                    compact: folderCompact,
                                    iconOnly: folderIconOnly,
                                    textScale: folderTextScale,
                                  ),
                                ),
                                _PaneResizeHandle(
                                  onDragDelta: (delta) {
                                    setState(() {
                                      _folderPaneWidth = (_folderPaneWidth + delta).clamp(
                                        _folderPaneMinWidth,
                                        _folderPaneMaxWidth,
                                      ).toDouble();
                                    });
                                  },
                                ),
                                SizedBox(
                                  width: itemsWidth,
                                  child: _LibraryItemsPane(
                                    controller: controller,
                                    onOpen: (item) => controller.selectItem(item.uid),
                                    compact: itemsCompact,
                                    textScale: itemsTextScale,
                                  ),
                                ),
                                _PaneResizeHandle(
                                  onDragDelta: (delta) {
                                    setState(() {
                                      _itemsPaneWidth = (_itemsPaneWidth + delta).clamp(
                                        _itemsPaneMinWidth,
                                        _itemsPaneMaxWidth,
                                      ).toDouble();
                                    });
                                  },
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                    Expanded(child: _LibraryWorkspace(item: selectedItem)),
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
              onPressed: () =>
                  Navigator.of(context).pop(textController.text),
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
}

class _FolderListPane extends StatelessWidget {
  const _FolderListPane({
    required this.controller,
    required this.onSelect,
    this.compact = false,
    this.iconOnly = false,
    this.textScale = 1.0,
  });

  final LibraryController controller;
  final ValueChanged<String> onSelect;
  final bool compact;
  final bool iconOnly;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    if (iconOnly) {
      final selectedColor = Theme.of(context)
          .colorScheme
          .primary
          .withValues(alpha: 0.14);
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Center(
            child: IconButton(
              tooltip: 'New folder',
              icon: const Icon(Icons.create_new_folder_outlined),
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  context.findAncestorStateOfType<_LibraryScreenState>()
                  ?._promptNewFolder(controller),
            ),
          ),
          const Divider(height: 1),
          for (final folder in controller.folderNames)
            Tooltip(
              message: folder,
              waitDuration: const Duration(milliseconds: 350),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: InkResponse(
                    onTap: () => onSelect(folder),
                    radius: 20,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: folder == controller.selectedFolder
                            ? selectedColor
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        folder == controller.selectedFolder
                            ? Icons.folder
                            : Icons.folder_outlined,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
              if (!compact)
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    style: (Theme.of(context).textTheme.titleSmall ??
                            const TextStyle())
                        .copyWith(
                          fontSize:
                              (Theme.of(context).textTheme.titleSmall?.fontSize ??
                                      14) *
                                  textScale,
                        ),
                    child: const Text(
                      'Folders',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              const Spacer(),
              IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.create_new_folder_outlined),
                visualDensity: compact
                    ? VisualDensity.compact
                    : VisualDensity.standard,
                onPressed: () =>
                    context.findAncestorStateOfType<_LibraryScreenState>()
                    ?._promptNewFolder(controller),
              ),
            ],
          ),
        ),
        for (final folder in controller.folderNames)
          ListTile(
            dense: compact,
            visualDensity: compact
                ? VisualDensity.compact
                : VisualDensity.standard,
            contentPadding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 16,
            ),
            title: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              style: (Theme.of(context).textTheme.bodyMedium ??
                      const TextStyle())
                  .copyWith(
                    fontSize:
                        (Theme.of(context).textTheme.bodyMedium?.fontSize ??
                                14) *
                            textScale,
                  ),
              child: Text(
                folder,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            selected: folder == controller.selectedFolder,
            onTap: () => onSelect(folder),
          ),
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            tooltip: 'New folder',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () =>
                context.findAncestorStateOfType<_LibraryScreenState>()
                ?._promptNewFolder(controller),
          ),
          const SizedBox(width: 8),
          for (final folder in controller.folderNames)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(folder),
                selected: folder == controller.selectedFolder,
                onSelected: (_) => onSelect(folder),
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
                  style: (Theme.of(context).textTheme.titleMedium ??
                          const TextStyle())
                      .copyWith(
                        fontSize:
                            (Theme.of(context).textTheme.titleMedium?.fontSize ??
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
    final isBoard = item.kind == NotebookKind.board;
    return ChangeNotifierProvider(
      create: (_) => EditorController(repository: repository, notebook: item),
      child: isBoard ? const BoardScreen() : const NotebookScreen(),
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
          child: Center(
            child: Container(
              width: 1,
              color: dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _LeftZoneToggleTab extends StatelessWidget {
  const _LeftZoneToggleTab({
    required this.expanded,
    required this.onPressed,
  });

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
