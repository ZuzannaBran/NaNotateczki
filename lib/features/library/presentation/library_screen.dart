import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/input/soft_keyboard.dart';
import '../../../core/widgets/empty_state.dart';
import '../../board/presentation/board_screen.dart';
import '../../editor/state/editor_controller.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../notebook/presentation/notebook_screen.dart';
import '../../planner/presentation/study_timer_widgets.dart';
import '../../planner/state/study_planner_controller.dart';
import 'library_controller.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const double _editorOverviewRight = 106;
  static const double _editorPageWidth = 820;
  static const double _editorPageMargin = 56;
  static const double _wideBreakpoint =
      _editorOverviewRight +
      _editorPageMargin +
      _editorPageWidth +
      _editorPageMargin;
  static const double _navigationPaneMinWidth = 240;
  static const double _navigationPaneMaxWidth = 420;
  static const double _resizeHandleWidth = 12;

  bool _showLeftNavigation = true;
  bool _showEditorToolbar = true;
  double _navigationPaneWidth = 320;
  bool _isShowingCorruptRecoveryDialog = false;
  StudyPlannerController? _studyPlanner;
  int _lastStudyNotice = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final planner = context.read<StudyPlannerController?>();
    if (!identical(_studyPlanner, planner)) {
      _studyPlanner?.removeListener(_onStudyNotice);
      _studyPlanner = planner;
      _lastStudyNotice = planner.noticeRevision;
      planner?.addListener(_onStudyNotice);
    }
  }

  @override
  void dispose() {
    _studyPlanner?.removeListener(_onStudyNotice);
    super.dispose();
  }

  void _onStudyNotice() {
    final planner = _studyPlanner;
    if (planner == null || planner.noticeRevision == _lastStudyNotice) {
      return;
    }
    _lastStudyNotice = planner.noticeRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final upcoming = planner.upcoming;
      final canStartNext = planner.active == null && upcoming.isNotEmpty;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 12),
          content: Text(planner.notice ?? "Great job! Time's up."),
          action: SnackBarAction(
            label: planner.active != null
                ? 'Planner'
                : canStartNext ? 'Start next' : 'New timer',
            onPressed: () {
              if (planner.active != null) {
                openStudyPlanner(context);
              } else if (canStartNext) {
                planner.start(upcoming.first.id);
              } else {
                showStudySessionEditor(context, startAfterSave: true);
              }
            },
          ),
        ),
      );
      if (planner.noticeRequiresReviewPrompt &&
          planner.pendingReviews.isNotEmpty && planner.active == null) {
        showStudyRating(context, planner.pendingReviews.last);
      }
    });
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
    _maybeShowCorruptRecoveryDialog(controller);

    return Scaffold(
      body: Column(
        children: [
          if (controller.shouldShowResetBanner)
            MaterialBanner(
              backgroundColor: Colors.amber.shade100,
              content: Text(
                controller.autoRestoreCount > 0
                    ? 'Local database recovery completed. Restored '
                          '${controller.autoRestoreCount} documents from the '
                          'local backup.'
                    : 'The previous local database was preserved after a '
                          'recovery event, but no documents were restored '
                          'automatically.',
              ),
              actions: [
                if (controller.autoRestoreCount == 0)
                  TextButton(
                    onPressed: controller.isLoading
                        ? null
                        : controller.loadItems,
                    child: const Text('Retry recovery'),
                  ),
                TextButton(
                  onPressed: controller.dismissResetBanner,
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          if (controller.shouldShowCorruptionBanner)
            MaterialBanner(
              backgroundColor: Colors.red.shade50,
              content: Text(
                controller.recoverableCorruptDocuments.isNotEmpty
                    ? 'Some documents could not be loaded. You can restore recovered copies from the local backup.'
                    : 'Some documents could not be loaded. No matching local backup copy was found.',
              ),
              actions: [
                if (controller.recoverableCorruptDocuments.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      final restored = await controller
                          .restoreCorruptDocumentsFromBackup();
                      if (!context.mounted) {
                        return;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            restored > 0
                                ? 'Recovered $restored document copies from the local backup.'
                                : 'No document copies were recovered.',
                          ),
                        ),
                      );
                    },
                    child: const Text('Recover'),
                  ),
                TextButton(
                  onPressed: controller.dismissCorruptRecoveryPrompt,
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          if (controller.loadError != null)
            MaterialBanner(
              backgroundColor: Colors.red.shade50,
              content: const Text(
                'The library could not be loaded. Existing documents were '
                'left unchanged.',
              ),
              actions: [
                TextButton(
                  onPressed: controller.isLoading ? null : controller.loadItems,
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final layoutWidth = math.max(
                  constraints.maxWidth,
                  _wideBreakpoint,
                );
                final maxNavigationWidth = math.max(
                  _navigationPaneMinWidth,
                  layoutWidth - 320,
                );
                final navigationMax = math.min(
                  _navigationPaneMaxWidth,
                  maxNavigationWidth,
                );
                final navigationWidth = _navigationPaneWidth
                    .clamp(_navigationPaneMinWidth, navigationMax)
                    .toDouble();
                final leftZoneWidth = _showLeftNavigation
                    ? navigationWidth + _resizeHandleWidth
                    : 0.0;

                final wideLayout = SizedBox(
                  width: layoutWidth,
                  height: constraints.maxHeight,
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: leftZoneWidth,
                            child: _showLeftNavigation
                                ? Row(
                                    children: [
                                      SizedBox(
                                        width: navigationWidth,
                                        child: _LibraryTreePane(
                                          controller: controller,
                                          onOpen: (item) =>
                                              controller.selectItem(item.uid),
                                          onCreate: _createAndSelectItem,
                                          onCreateFolder: () {
                                            _promptNewFolder(controller);
                                          },
                                        ),
                                      ),
                                      _PaneResizeHandle(
                                        onDragDelta: (delta) {
                                          setState(() {
                                            _navigationPaneWidth =
                                                (_navigationPaneWidth + delta)
                                                    .clamp(
                                                      _navigationPaneMinWidth,
                                                      _navigationPaneMaxWidth,
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
                            child: _LibraryWorkspace(
                              item: selectedItem,
                              showToolbar: _showEditorToolbar,
                              showCompactTimer: !_showLeftNavigation,
                            ),
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
                      Positioned(
                        left: math.max(0.0, leftZoneWidth - 1),
                        top: 50,
                        child: _LeftZoneToggleTab(
                          expanded: _showEditorToolbar,
                          toolbar: true,
                          onPressed: () {
                            setState(() {
                              _showEditorToolbar = !_showEditorToolbar;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                );

                if (constraints.maxWidth >= _wideBreakpoint) {
                  return wideLayout;
                }

                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: wideLayout,
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

  Future<Notebook> _createItem(NotebookKind kind) {
    final controller = context.read<LibraryController>();
    return switch (kind) {
      NotebookKind.notebook => controller.createNotebook(),
      NotebookKind.board => controller.createBoard(),
    };
  }

  Future<void> _createAndSelectItem(NotebookKind kind) async {
    final controller = context.read<LibraryController>();
    final item = await _createItem(kind);
    if (!mounted) {
      return;
    }
    await _promptRenameItem(controller, item);
  }

  Future<void> _promptNewFolder(LibraryController controller) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const _NameInputDialog(
        title: 'New folder',
        hintText: 'Folder name',
        actionLabel: 'Create',
      ),
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
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _NameInputDialog(
        title: 'Rename folder',
        hintText: 'Folder name',
        actionLabel: 'Rename',
        initialText: folder,
      ),
    );

    if (result == null) {
      return;
    }
    await controller.renameFolder(folder, result);
  }

  Future<void> _promptRenameItem(
    LibraryController controller,
    Notebook item,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _NameInputDialog(
        title: 'Rename item',
        hintText: 'Item name',
        actionLabel: 'Rename',
        initialText: item.title,
        selectAll: true,
      ),
    );

    if (result == null) {
      return;
    }
    await controller.renameItem(item.uid, result);
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

  Future<void> _confirmDeleteItem(
    LibraryController controller,
    Notebook item,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete item?'),
          content: Text('This will permanently delete "${item.title}".'),
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
    await controller.deleteItem(item.uid);
  }

  void _maybeShowCorruptRecoveryDialog(LibraryController controller) {
    if (!controller.shouldPromptCorruptRecovery ||
        _isShowingCorruptRecoveryDialog) {
      return;
    }
    _isShowingCorruptRecoveryDialog = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final names = controller.recoverableCorruptDocuments
          .take(4)
          .map((item) => item.title.trim().isEmpty ? 'Untitled' : item.title)
          .toList();
      final sample = names.join(', ');
      final extraCount =
          controller.recoverableCorruptDocuments.length - names.length;
      final details = sample.isEmpty
          ? '${controller.corruptDocumentCount} unreadable documents were detected.'
          : extraCount > 0
          ? '$sample and $extraCount more.'
          : sample;

      final shouldRecover = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            title: const Text('Damaged documents detected'),
            content: Text(
              'Some documents could not be opened. '
              'Recoverable copies were found in the local backup: $details\n\n'
              'Recovered copies will be added as separate documents so the '
              'original damaged data is not overwritten.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('No'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Yes'),
              ),
            ],
          );
        },
      );

      _isShowingCorruptRecoveryDialog = false;
      if (!mounted) {
        return;
      }
      if (shouldRecover == true) {
        final restored = await controller.restoreCorruptDocumentsFromBackup();
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              restored > 0
                  ? 'Recovered $restored document copies from the local backup.'
                  : 'No document copies were recovered.',
            ),
          ),
        );
        return;
      }
      controller.dismissCorruptRecoveryPrompt();
    });
  }
}

class _NameInputDialog extends StatefulWidget {
  const _NameInputDialog({
    required this.title,
    required this.hintText,
    required this.actionLabel,
    this.initialText = '',
    this.selectAll = false,
  });

  final String title;
  final String hintText;
  final String actionLabel;
  final String initialText;
  final bool selectAll;

  @override
  State<_NameInputDialog> createState() => _NameInputDialogState();
}

class _NameInputDialogState extends State<_NameInputDialog> {
  late final TextEditingController _textController;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
    if (widget.selectAll) {
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        requestSoftKeyboardForFocus(context, _focusNode);
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _textController,
        focusNode: _focusNode,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hintText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_textController.text),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

enum _FolderAction { rename, delete }

enum _ItemAction { rename, delete }

const TextStyle _sidebarTextStyle = TextStyle(
  fontSize: 14,
  height: 1.2,
  letterSpacing: -0.05,
);

class _LibraryTreePane extends StatefulWidget {
  const _LibraryTreePane({
    required this.controller,
    required this.onOpen,
    required this.onCreate,
    required this.onCreateFolder,
  });

  final LibraryController controller;
  final ValueChanged<Notebook> onOpen;
  final Future<void> Function(NotebookKind kind) onCreate;
  final VoidCallback onCreateFolder;

  @override
  State<_LibraryTreePane> createState() => _LibraryTreePaneState();
}

class _LibraryTreePaneState extends State<_LibraryTreePane> {
  final Set<String> _collapsedFolders = <String>{};

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final colorScheme = Theme.of(context).colorScheme;
    final folders = controller.folderNames;

    return DecoratedBox(
      decoration: BoxDecoration(color: colorScheme.surfaceContainerLowest),
      child: Column(
        children: [
          SizedBox(
            height: 58,
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Projects',
                      overflow: TextOverflow.ellipsis,
                      style: _sidebarTextStyle.copyWith(
                        color: colorScheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  PopupMenuButton<_CreateAction>(
                    tooltip: 'Create',
                    icon: const Icon(Icons.add_rounded, size: 21),
                    onSelected: _handleCreateAction,
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _CreateAction.folder,
                        child: Row(
                          children: [
                            Icon(Icons.create_new_folder_outlined),
                            SizedBox(width: 10),
                            Text('New folder'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: _CreateAction.notebook,
                        child: Row(
                          children: [
                            Icon(Icons.description_outlined),
                            SizedBox(width: 10),
                            Text('New notebook'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: _CreateAction.board,
                        child: Row(
                          children: [
                            Icon(Icons.dashboard_outlined),
                            SizedBox(width: 10),
                            Text('New board'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.45),
          ),
          Expanded(
            child: controller.isLoading
                ? const Center(child: CircularProgressIndicator())
                : folders.isEmpty
                ? _EmptyLibraryTree(onCreate: _handleCreateAction)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(6, 8, 6, 12),
                    children: [
                      for (final folder in folders) _buildFolder(folder),
                    ],
                  ),
          ),
          SizedBox(
            height: math.min(360, MediaQuery.sizeOf(context).height * 0.42),
            child: const SingleChildScrollView(
              child: StudyTimerCard(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolder(String folder) {
    final controller = widget.controller;
    final expanded = !_collapsedFolders.contains(folder);
    final items = controller.items
        .where((item) => item.folder == folder)
        .toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FolderTreeRow(
            folder: folder,
            expanded: expanded,
            selected: controller.selectedFolder == folder,
            onToggle: () {
              setState(() {
                if (expanded) {
                  _collapsedFolders.add(folder);
                } else {
                  _collapsedFolders.remove(folder);
                }
              });
            },
            onTap: () => controller.selectFolder(folder),
            onRename: () => context
                .findAncestorStateOfType<_LibraryScreenState>()
                ?._promptRenameFolder(controller, folder),
            onDelete: () => context
                .findAncestorStateOfType<_LibraryScreenState>()
                ?._confirmDeleteFolder(controller, folder),
          ),
          if (expanded)
            for (final item in items)
              _LibraryTreeItemRow(
                item: item,
                selected: controller.selectedItemId == item.uid,
                onTap: () => widget.onOpen(item),
                onRename: () => context
                    .findAncestorStateOfType<_LibraryScreenState>()
                    ?._promptRenameItem(controller, item),
                onDelete: () => context
                    .findAncestorStateOfType<_LibraryScreenState>()
                    ?._confirmDeleteItem(controller, item),
              ),
        ],
      ),
    );
  }

  void _handleCreateAction(_CreateAction action) {
    switch (action) {
      case _CreateAction.folder:
        widget.onCreateFolder();
        return;
      case _CreateAction.notebook:
        widget.onCreate(NotebookKind.notebook);
        return;
      case _CreateAction.board:
        widget.onCreate(NotebookKind.board);
        return;
    }
  }
}

class _EmptyLibraryTree extends StatelessWidget {
  const _EmptyLibraryTree({required this.onCreate});

  final ValueChanged<_CreateAction> onCreate;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_outlined,
              size: 28,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              'No projects yet',
              style: _sidebarTextStyle.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Create a folder or note to get started.',
              style: _sidebarTextStyle.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => onCreate(_CreateAction.folder),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('New folder'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderTreeRow extends StatelessWidget {
  const _FolderTreeRow({
    required this.folder,
    required this.expanded,
    required this.selected,
    required this.onToggle,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final String folder;
  final bool expanded;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? colorScheme.surfaceContainerHighest
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
          onTap: onTap,
          child: SizedBox(
            height: 38,
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: IconButton(
                    tooltip: expanded ? 'Collapse $folder' : 'Expand $folder',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 36,
                    ),
                    splashRadius: 16,
                    onPressed: onToggle,
                    icon: Icon(
                      expanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_right_rounded,
                      size: 19,
                    ),
                  ),
                ),
                Icon(
                  expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    folder,
                    style: _sidebarTextStyle.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                PopupMenuButton<_FolderAction>(
                  tooltip: 'Folder actions',
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  padding: EdgeInsets.zero,
                  onSelected: (action) {
                    if (action == _FolderAction.rename) {
                      onRename();
                    } else {
                      onDelete();
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
        ),
      ),
    );
  }
}

class _LibraryTreeItemRow extends StatelessWidget {
  const _LibraryTreeItemRow({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Notebook item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      key: ValueKey('library-tree-item:${item.uid}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? colorScheme.surfaceContainerHighest
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
          onTap: onTap,
          child: SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 38),
                Icon(
                  item.kind == NotebookKind.board
                      ? Icons.dashboard_outlined
                      : Icons.description_outlined,
                  size: 15,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    item.title,
                    style: _sidebarTextStyle.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                PopupMenuButton<_ItemAction>(
                  tooltip: 'Item actions',
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    size: 17,
                    color: colorScheme.onSurfaceVariant,
                  ),
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
                      child: Text('Rename'),
                    ),
                    PopupMenuItem(
                      value: _ItemAction.delete,
                      child: Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryWorkspace extends StatelessWidget {
  const _LibraryWorkspace({
    required this.item,
    required this.showToolbar,
    required this.showCompactTimer,
  });

  final Notebook? item;
  final bool showToolbar;
  final bool showCompactTimer;

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
      child: isBoard
          ? BoardScreen(
              showToolbar: showToolbar,
              showCompactTimer: showCompactTimer,
            )
          : NotebookScreen(
              showToolbar: showToolbar,
              showCompactTimer: showCompactTimer,
            ),
    );
  }
}

enum _CreateAction { folder, notebook, board }

class _PaneResizeHandle extends StatelessWidget {
  const _PaneResizeHandle({required this.onDragDelta});

  final ValueChanged<double> onDragDelta;

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: 0.45);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDragDelta(details.delta.dx),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          child: SizedBox(
            width: _LibraryScreenState._resizeHandleWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(width: 1, color: dividerColor),
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
    this.toolbar = false,
  });

  final bool expanded;
  final VoidCallback onPressed;
  final bool toolbar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: ValueKey(
        toolbar ? 'editor-toolbar-toggle' : 'library-navigation-toggle',
      ),
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
        child: Tooltip(
          message: toolbar
              ? (expanded ? 'Hide toolbar' : 'Show toolbar')
              : (expanded ? 'Hide projects' : 'Show projects'),
          child: SizedBox(
            width: 32,
            height: 44,
            child: Icon(
              toolbar
                  ? (expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded)
                  : (expanded ? Icons.chevron_left : Icons.chevron_right),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
