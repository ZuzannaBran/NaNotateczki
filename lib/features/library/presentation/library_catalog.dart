import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_drawing/path_drawing.dart';
import 'package:provider/provider.dart';

import '../../../core/input/app_preferences_controller.dart';
import '../../../core/input/touch_navigation_scroll_physics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_dialog_actions.dart';
import '../../../core/widgets/app_header_divider.dart';
import '../../editor/presentation/widgets/editor_toolbar.dart';
import '../../editor/state/ink_color_presets.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../planner/presentation/study_timer_widgets.dart';
import 'library_controller.dart';

/// Finds the most frequently used ink/text color in a folder.
Color dominantFolderColor(Iterable<Notebook> notebooks) {
  final counts = <int, int>{};
  for (final notebook in notebooks) {
    for (final page in notebook.pages) {
      for (final stroke in page.inkStrokes) {
        if (stroke.tool.isEraser || stroke.points.isEmpty) {
          continue;
        }
        final color = stroke.color.toARGB32();
        counts[color] = (counts[color] ?? 0) + 1;
      }
      for (final block in page.textBlocks) {
        if (block.text.trim().isEmpty) {
          continue;
        }
        final color = block.color.toARGB32();
        counts[color] = (counts[color] ?? 0) + 1;
      }
    }
  }
  if (counts.isEmpty) {
    return AppColors.divider;
  }
  final chosen = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  return Color(chosen.key);
}

/// Lucide SVG outlines with a fixed, delicate stroke at any icon size.
class FolderCoverIcon extends StatelessWidget {
  const FolderCoverIcon({
    required this.shape,
    required this.color,
    this.size = 88,
    this.semanticLabel,
    super.key,
  });

  // A slightly broader, translucent stroke stays delicate without aliasing.
  static const double strokeWidth = 1.25;

  final FolderCoverShape shape;
  final Color color;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      label: semanticLabel,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              key: const ValueKey('folder-cover-outline'),
              painter: FolderCoverStrokePainter(
                shape: shape,
                color: color,
                isDecoration: false,
                devicePixelRatio: devicePixelRatio,
              ),
            ),
            if (shape != FolderCoverShape.folder)
              CustomPaint(
                key: const ValueKey('folder-cover-decoration'),
                painter: FolderCoverStrokePainter(
                  shape: shape,
                  color: color,
                  isDecoration: true,
                  devicePixelRatio: devicePixelRatio,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Uses the original Lucide vector geometry without scaling stroke weight.
class FolderCoverStrokePainter extends CustomPainter {
  const FolderCoverStrokePainter({
    required this.shape,
    required this.color,
    required this.isDecoration,
    this.devicePixelRatio = 1.0,
  });

  final FolderCoverShape shape;
  final Color color;
  final bool isDecoration;
  final double devicePixelRatio;

  double get strokeWidth => FolderCoverIcon.strokeWidth;

  // Keep the soft edge approximately half a physical pixel on all screens.
  double get smoothingSigma => 0.55 / devicePixelRatio;

  static final Path _folder = parseSvgPathData(
    'M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9'
    'a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4'
    'a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z',
  );
  static final Path _star = parseSvgPathData(
    'M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679'
    'a2.123 2.123 0 0 0 1.595 1.16l5.166.756'
    'a.53.53 0 0 1 .294.904l-3.736 3.638'
    'a2.123 2.123 0 0 0-.611 1.878l.882 5.14'
    'a.53.53 0 0 1-.771.56l-4.618-2.428'
    'a2.122 2.122 0 0 0-1.973 0L6.396 21.01'
    'a.53.53 0 0 1-.77-.56l.881-5.139'
    'a2.122 2.122 0 0 0-.611-1.879L2.16 9.795'
    'a.53.53 0 0 1 .294-.906l5.165-.755'
    'a2.122 2.122 0 0 0 1.597-1.16z',
  );
  static final Path _heart = parseSvgPathData(
    'M2 9.5a5.5 5.5 0 0 1 9.591-3.676'
    'a.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5'
    'c0 2.29-1.5 4-3 5.5l-5.492 5.313'
    'a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5',
  );
  static final Path _flower = Path()
    ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 3))
    ..addPath(
      parseSvgPathData(
        'M12 16.5A4.5 4.5 0 1 1 7.5 12'
        ' 4.5 4.5 0 1 1 12 7.5'
        'a4.5 4.5 0 1 1 4.5 4.5'
        ' 4.5 4.5 0 1 1-4.5 4.5',
      ),
      Offset.zero,
    )
    ..addPath(
      parseSvgPathData(
        'M12 7.5V9M7.5 12H9M16.5 12H15M12 16.5V15'
        'm-4-7 1.88 1.88M14.12 9.88 16 8'
        'm-8 8 1.88-1.88M14.12 14.12 16 16',
      ),
      Offset.zero,
    );
  static final Path _sparkles = Path()
    ..addPath(
      parseSvgPathData(
        'M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558'
        'a2 2 0 0 0 1.594 1.594l5.558 1.051'
        'a1 1 0 0 1 0 1.966l-5.558 1.051'
        'a2 2 0 0 0-1.594 1.594l-1.051 5.558'
        'a1 1 0 0 1-1.966 0l-1.051-5.558'
        'a2 2 0 0 0-1.594-1.594l-5.558-1.051'
        'a1 1 0 0 1 0-1.966l5.558-1.051'
        'a2 2 0 0 0 1.594-1.594z',
      ),
      Offset.zero,
    )
    ..addPath(parseSvgPathData('M20 2v4M22 4h-4'), Offset.zero)
    ..addOval(Rect.fromCircle(center: const Offset(4, 20), radius: 2));

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    if (side <= 0) {
      return;
    }
    final scale = side / 24;
    final decorationScale = isDecoration ? 0.3 : 1.0;

    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(scale);
    if (isDecoration) {
      canvas.translate(8.4, 10.2);
      canvas.scale(decorationScale);
    }
    final stroke = Paint()
      ..color = color.withValues(alpha: color.a * 0.86)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth / (scale * decorationScale)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        smoothingSigma / (scale * decorationScale),
      );

    final path = isDecoration
        ? switch (shape) {
            FolderCoverShape.folder => _folder,
            FolderCoverShape.star => _star,
            FolderCoverShape.heart => _heart,
            FolderCoverShape.flower => _flower,
            FolderCoverShape.sparkle => _sparkles,
          }
        : _folder;
    canvas.drawPath(path, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant FolderCoverStrokePainter oldDelegate) =>
      shape != oldDelegate.shape ||
      color != oldDelegate.color ||
      isDecoration != oldDelegate.isDecoration ||
      devicePixelRatio != oldDelegate.devicePixelRatio;
}

class LibraryCatalog extends StatelessWidget {
  const LibraryCatalog({
    required this.controller,
    required this.folder,
    required this.onBack,
    required this.onFolderTap,
    required this.onOpenItem,
    required this.onEditFolder,
    required this.onRenameFolder,
    required this.onDeleteFolder,
    required this.onRenameItem,
    required this.onDeleteItem,
    required this.onSettings,
    this.showCompactTimer = false,
    super.key,
  });

  final LibraryController controller;
  final String? folder;
  final VoidCallback onBack;
  final ValueChanged<String> onFolderTap;
  final ValueChanged<Notebook> onOpenItem;
  final ValueChanged<String> onEditFolder;
  final ValueChanged<String> onRenameFolder;
  final ValueChanged<String> onDeleteFolder;
  final ValueChanged<Notebook> onRenameItem;
  final ValueChanged<Notebook> onDeleteItem;
  final VoidCallback onSettings;
  final bool showCompactTimer;

  @override
  Widget build(BuildContext context) {
    final activeFolder = folder;
    final folders = controller.folderNames;
    final notes = activeFolder == null
        ? <Notebook>[]
        : controller.items
              .where((item) => item.folder == activeFolder)
              .toList();
    final useWideTitleInset = MediaQuery.sizeOf(context).width >= 600;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: AppHeaderDivider.toolbarHeight,
        automaticallyImplyLeading: false,
        titleSpacing: useWideTitleInset ? 44 : null,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          activeFolder ?? 'Library',
          key: const ValueKey('catalog-title'),
          style: AppHeaderDivider.titleStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (showCompactTimer) const CompactStudyTimer(),
          if (activeFolder != null)
            IconButton(
              tooltip: 'Edit folder cover',
              icon: const Icon(Icons.palette_outlined),
              onPressed: () => onEditFolder(activeFolder),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: onSettings,
          ),
        ],
      ),
      body: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          children: [
            if (activeFolder != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(30, 8, 30, 0),
                  child: TextButton.icon(
                    key: const ValueKey('catalog-back'),
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                    label: const Text('All projects'),
                  ),
                ),
              ),
            Expanded(
              child: controller.isLoading && controller.items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : activeFolder == null && folders.isEmpty
                  ? const _CatalogEmptyState(
                      icon: Icons.folder_open_outlined,
                      title: 'No folders yet',
                      subtitle: 'Create a folder using the Projects menu.',
                    )
                  : activeFolder != null && notes.isEmpty
                  ? const _CatalogEmptyState(
                      icon: Icons.note_add_outlined,
                      title: 'This folder is empty',
                      subtitle: 'Add a notebook or board using the + menu.',
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        if (activeFolder == null) {
                          const cellExtent = 246.0;
                          const rowExtent = 292.0;
                          final availableWidth = math.max(
                            1.0,
                            constraints.maxWidth - 40,
                          );
                          final columns = math.min(
                            5,
                            math.min(
                              folders.length,
                              math.max(
                                1,
                                (availableWidth / cellExtent).floor(),
                              ),
                            ),
                          );
                          final gridWidth = math.min(
                            availableWidth,
                            columns * cellExtent,
                          );
                          final cellWidth = gridWidth / columns;
                          final rowCount =
                              (folders.length + columns - 1) ~/ columns;

                          return SingleChildScrollView(
                            key: const ValueKey('catalog-folders'),
                            physics: TouchNavigationScrollPhysics(
                              sensitivity:
                                  context
                                      .watch<AppPreferencesController?>()
                                      ?.touchNavigationSensitivity ??
                                  1.0,
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 24,
                                  ),
                                  child: SizedBox(
                                    key: const ValueKey('catalog-folder-grid'),
                                    width: gridWidth,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        for (
                                          var row = 0;
                                          row < rowCount;
                                          row++
                                        ) ...[
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.start,
                                            children: [
                                              for (
                                                var index = row * columns;
                                                index <
                                                    math.min(
                                                      (row + 1) * columns,
                                                      folders.length,
                                                    );
                                                index++
                                              )
                                                SizedBox(
                                                  width: cellWidth,
                                                  height: rowExtent,
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(18),
                                                    child: _FolderTile(
                                                      name: folders[index],
                                                      cover: controller
                                                          .folderCoverFor(
                                                            folders[index],
                                                          ),
                                                      onTap: () => onFolderTap(
                                                        folders[index],
                                                      ),
                                                      onEdit: () => onEditFolder(
                                                        folders[index],
                                                      ),
                                                      onRename: () =>
                                                          onRenameFolder(
                                                            folders[index],
                                                          ),
                                                      onDelete: () =>
                                                          onDeleteFolder(
                                                            folders[index],
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }
                        return GridView.builder(
                          physics: TouchNavigationScrollPhysics(
                            sensitivity:
                                context
                                    .watch<AppPreferencesController?>()
                                    ?.touchNavigationSensitivity ??
                                1.0,
                          ),
                          key: ValueKey('catalog-items:$activeFolder'),
                          padding: const EdgeInsets.all(30),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 224,
                                mainAxisExtent: 263,
                                mainAxisSpacing: 24,
                                crossAxisSpacing: 24,
                              ),
                          itemCount: notes.length,
                          itemBuilder: (context, index) {
                            final item = notes[index];
                            return _DocumentTile(
                              item: item,
                              onTap: () => onOpenItem(item),
                              onRename: () => onRenameItem(item),
                              onDelete: () => onDeleteItem(item),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogEmptyState extends StatelessWidget {
  const _CatalogEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: Theme.of(context).colorScheme.onSurface),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(subtitle),
        ],
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.name,
    required this.cover,
    required this.onTap,
    required this.onEdit,
    required this.onRename,
    required this.onDelete,
  });

  final String name;
  final FolderCoverStyle cover;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final darkMode = theme.brightness == Brightness.dark;
    final background = darkMode ? AppColors.darkPaper : AppColors.paper;
    final iconColor = cover.iconColor == null
        ? theme.colorScheme.onSurface
        : AppColors.displayInkColor(cover.iconColor!, darkMode: darkMode);
    return _CatalogTile(
      key: ValueKey('catalog-folder:$name'),
      title: name,
      onTap: onTap,
      actions: [
        PopupMenuItem(value: 0, child: const Text('Edit cover')),
        PopupMenuItem(value: 1, child: const Text('Rename')),
        PopupMenuItem(value: 2, child: const Text('Delete')),
      ],
      onAction: (value) {
        switch (value) {
          case 0:
            onEdit();
          case 1:
            onRename();
          case 2:
            onDelete();
        }
      },
      child: Ink(
        key: ValueKey('catalog-folder-cover:$name'),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(
              alpha: darkMode ? 0.30 : 0.22,
            ),
          ),
        ),
        child: Center(
          child: FolderCoverIcon(
            shape: cover.shape,
            color: iconColor,
            semanticLabel: '$name cover',
          ),
        ),
      ),
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.item,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Notebook item;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return _CatalogTile(
      key: ValueKey('catalog-document:${item.uid}'),
      title: item.title,
      onTap: onTap,
      actions: const [
        PopupMenuItem(value: 0, child: Text('Rename')),
        PopupMenuItem(value: 1, child: Text('Delete')),
      ],
      onAction: (action) {
        if (action == 0) {
          onRename();
        } else {
          onDelete();
        }
      },
      child: Center(
        child: AspectRatio(
          aspectRatio: item.kind == NotebookKind.board ? 1 : 0.72,
          child: _DocumentPreview(item: item),
        ),
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.title,
    required this.child,
    required this.onTap,
    required this.actions,
    required this.onAction,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback onTap;
  final List<PopupMenuItem<int>> actions;
  final ValueChanged<int> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final darkMode = theme.brightness == Brightness.dark;
    final hoverColor = (darkMode ? AppColors.darkActive : AppColors.toolbar)
        .withValues(alpha: darkMode ? 0.32 : 0.52);
    final pressedColor = (darkMode ? AppColors.darkActive : AppColors.divider)
        .withValues(alpha: darkMode ? 0.52 : 0.42);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SizedBox(
            height: 34,
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: PopupMenuButton<int>(
                    tooltip: 'Actions for $title',
                    icon: const Icon(Icons.more_horiz_rounded, size: 19),
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      fixedSize: const Size(32, 32),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onSelected: onAction,
                    itemBuilder: (_) => actions,
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(24),
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return pressedColor;
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)) {
                  return hoverColor;
                }
                return Colors.transparent;
              }),
              splashColor: pressedColor,
              highlightColor: Colors.transparent,
              child: Padding(padding: const EdgeInsets.all(4), child: child),
            ),
          ),
        ),
      ],
    );
  }
}

class _DocumentPreview extends StatelessWidget {
  const _DocumentPreview({required this.item});

  final Notebook item;

  @override
  Widget build(BuildContext context) {
    final page = item.pages.isEmpty ? null : item.pages.first;
    final theme = Theme.of(context);
    final darkMode = theme.brightness == Brightness.dark;
    final paper = darkMode ? AppColors.darkCanvas : AppColors.paper;
    final board = item.kind == NotebookKind.board;
    final bounds = board
        ? _boardPreviewBounds(page)
        : const Rect.fromLTWH(0, 0, 820, 1160);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: paper,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: const [BoxShadow(color: AppColors.shadow, blurRadius: 5)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: page == null
            ? Center(
                child: Icon(
                  board ? Icons.dashboard_outlined : Icons.description_outlined,
                  size: 46,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: bounds.width,
                  height: bounds.height,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned.fill(child: ColoredBox(color: paper)),
                      for (final image in page.imageBlocks)
                        _imagePreview(image, bounds, theme),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _PagePreviewPainter(
                            page,
                            bounds.topLeft,
                            darkMode: darkMode,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _imagePreview(ImageBlock block, Rect bounds, ThemeData theme) {
    Widget preview;
    if (block.bytes != null) {
      preview = Image.memory(block.bytes!, fit: BoxFit.fill);
    } else if (!kIsWeb && block.path.isNotEmpty) {
      preview = Image.file(
        File(block.path),
        fit: BoxFit.fill,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    } else {
      preview = ColoredBox(color: theme.colorScheme.surfaceContainerLow);
    }
    return Positioned(
      left: block.position.dx - bounds.left,
      top: block.position.dy - bounds.top,
      width: math.max(1, block.width),
      height: math.max(1, block.height),
      child: Transform.rotate(angle: block.rotation, child: preview),
    );
  }
}

Rect _boardPreviewBounds(NotePage? page) {
  if (page == null) {
    return const Rect.fromLTWH(-400, -400, 800, 800);
  }
  Rect? content;
  void include(Rect bounds) {
    content = content == null ? bounds : content!.expandToInclude(bounds);
  }

  for (final stroke in page.inkStrokes) {
    for (final point in stroke.points) {
      include(Rect.fromCircle(center: point.toOffset(), radius: 2));
    }
  }
  for (final image in page.imageBlocks) {
    include(
      Rect.fromLTWH(
        image.position.dx,
        image.position.dy,
        math.max(1, image.width),
        math.max(1, image.height),
      ),
    );
  }
  for (final block in page.textBlocks) {
    include(
      Rect.fromLTWH(
        block.position.dx,
        block.position.dy,
        math.max(1, block.width),
        math.max(36, block.fontSize * 3),
      ),
    );
  }
  if (content == null) {
    return const Rect.fromLTWH(-400, -400, 800, 800);
  }
  final padded = content!.inflate(100);
  final side = math.max(600.0, math.max(padded.width, padded.height));
  return Rect.fromCenter(center: padded.center, width: side, height: side);
}

class _PagePreviewPainter extends CustomPainter {
  const _PagePreviewPainter(this.page, this.origin, {required this.darkMode});

  final NotePage page;
  final Offset origin;
  final bool darkMode;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(-origin.dx, -origin.dy);
    for (final stroke in page.inkStrokes) {
      if (stroke.tool.isEraser || stroke.points.isEmpty) {
        continue;
      }
      final color = AppColors.displayInkColor(stroke.color, darkMode: darkMode);
      final ink = Paint()
        ..color = stroke.tool == DrawingTool.highlighter
            ? color.withValues(alpha: 0.42)
            : color
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          stroke.points.first.toOffset(),
          math.max(0.5, stroke.width / 2),
          ink..style = PaintingStyle.fill,
        );
      } else {
        final path = Path()
          ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
        for (final point in stroke.points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, ink);
      }
    }
    for (final block in page.textBlocks) {
      if (block.text.isEmpty) {
        continue;
      }
      final painter = TextPainter(
        text: TextSpan(
          text: block.text,
          style: TextStyle(
            color: AppColors.displayInkColor(block.color, darkMode: darkMode),
            fontSize: block.fontSize,
            fontFamily: 'Georgia',
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 12,
        ellipsis: '…',
      )..layout(maxWidth: math.max(1, block.width));
      canvas.save();
      canvas.translate(block.position.dx, block.position.dy);
      canvas.rotate(block.rotation);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PagePreviewPainter oldDelegate) =>
      !identical(page, oldDelegate.page) ||
      origin != oldDelegate.origin ||
      darkMode != oldDelegate.darkMode;
}

Future<void> showFolderCoverEditor(
  BuildContext context,
  LibraryController controller,
  String folder,
) async {
  final saved = controller.folderCoverFor(folder);
  var shape = saved.shape;
  Color? iconColor = saved.iconColor;
  final darkMode = Theme.of(context).brightness == Brightness.dark;
  const colors = <Color>[
    AppColors.inkBlack,
    Color(0xFFB33636),
    Color(0xFFB9792A),
    Color(0xFF2E7D32),
    Color(0xFF2E5AAC),
    Color(0xFF6A4C93),
    Color(0xFFB8749A),
  ];
  final result = await showDialog<FolderCoverStyle>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('Edit folder cover'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Cover decoration'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final option in FolderCoverShape.values)
                        ChoiceChip(
                          key: ValueKey('cover-shape:${option.name}'),
                          label: FolderCoverIcon(
                            shape: option,
                            color: Theme.of(context).colorScheme.onSurface,
                            size: 40,
                            semanticLabel: option.name,
                          ),
                          selected: shape == option,
                          onSelected: (_) => update(() => shape = option),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                    const Text('Cover color'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final color in colors)
                      InkWell(
                        key: ValueKey('cover-color:${color.toARGB32()}'),
                        borderRadius: BorderRadius.circular(30),
                        onTap: () => update(() => iconColor = color),
                        child: CircleAvatar(
                          radius: 19,
                          backgroundColor: AppColors.displayInkColor(
                            color,
                            darkMode: darkMode,
                          ),
                          child: iconColor == color
                              ? Icon(
                                  Icons.check,
                                  color: Theme.of(context).colorScheme.onSurface,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Recent', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final color in controller.recentCoverColors)
                      InkWell(
                        key: ValueKey(
                          'cover-recent-${color.toARGB32()}',
                        ),
                        borderRadius: BorderRadius.circular(30),
                        onTap: () => update(() => iconColor = color),
                        child: CircleAvatar(
                          radius: 15,
                          backgroundColor: AppColors.displayInkColor(
                            color,
                            darkMode: darkMode,
                          ),
                          child: iconColor == color
                              ? Icon(
                                  Icons.check,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.onSurface,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Palettes', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    for (final preset in InkColorPreset.values)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final color in preset.colors)
                                InkWell(
                                  key: ValueKey(
                                    'cover-palette-${preset.name}-'
                                    '${color.toARGB32()}',
                                  ),
                                  onTap: () => update(() => iconColor = color),
                                  child: Container(
                                    width: 26,
                                    height: 28,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: AppColors.displayInkColor(
                                        color,
                                        darkMode: darkMode,
                                      ),
                                      border: Border.all(
                                        color: Theme.of(context).dividerColor,
                                        width: 0.5,
                                      ),
                                    ),
                                    child: iconColor == color
                                        ? Icon(
                                            Icons.check,
                                            size: 15,
                                            color: Theme.of(context)
                                                .colorScheme.onSurface,
                                          )
                                        : null,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            preset.label,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  key: const ValueKey('cover-advanced-color'),
                  onPressed: () async {
                    final picked = await EditorToolbar.pickColor(
                      context,
                      iconColor ?? AppColors.inkBlack,
                      controller.recentCoverColors,
                      onPaletteColorSelected: (color) {
                        if (context.mounted) {
                          update(() => iconColor = color);
                        }
                      },
                    );
                    if (picked != null && context.mounted) {
                      update(() => iconColor = picked);
                    }
                  },
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Custom color / HEX'),
                ),
                TextButton(
                  onPressed: () => update(() => iconColor = null),
                  child: const Text('Default cover color'),
                ),
              ],
            ),
          ),
        ),
        actions: appDialogActions(context, [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              FolderCoverStyle(shape: shape, iconColor: iconColor),
            ),
            child: const Text('Save'),
          ),
        ]),
      ),
    ),
  );
  if (result != null) {
    await controller.updateFolderCover(folder, result);
  }
}
