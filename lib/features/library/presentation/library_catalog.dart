import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/input/app_preferences_controller.dart';
import '../../../core/input/touch_navigation_scroll_physics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_dialog_actions.dart';
import '../../../core/widgets/app_header_divider.dart';
import '../../editor/presentation/widgets/editor_toolbar.dart';
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

/// Renders a consistent outlined folder, with an optional cover decoration.
class FolderCoverIcon extends StatelessWidget {
  const FolderCoverIcon({
    required this.shape,
    required this.color,
    this.size = 88,
    this.semanticLabel,
    super.key,
  });

  final FolderCoverShape shape;
  final Color color;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              key: const ValueKey('folder-cover-outline'),
              painter: _FolderOutlinePainter(color),
            ),
            if (shape != FolderCoverShape.folder)
              CustomPaint(
                key: const ValueKey('folder-cover-decoration'),
                painter: _FolderDecorationPainter(shape, color),
              ),
          ],
        ),
      ),
    );
  }
}

void _paintFolderLineArt(
  Canvas canvas,
  Size size,
  Color color,
  void Function(Paint) draw,
) {
  final scale = size.shortestSide / 100;
  if (scale <= 0) {
    return;
  }
  canvas.save();
  canvas.translate(
    (size.width - 100 * scale) / 2,
    (size.height - 100 * scale) / 2,
  );
  canvas.scale(scale);
  final stroke = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = (size.shortestSide >= 50 ? 1.6 : 1.1) / scale
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  draw(stroke);
  canvas.restore();
}

class _FolderOutlinePainter extends CustomPainter {
  const _FolderOutlinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    _paintFolderLineArt(canvas, size, color, (stroke) {
      final outline = Path()
        ..moveTo(17, 29)
        ..lineTo(37, 29)
        ..quadraticBezierTo(40, 29, 43, 33)
        ..lineTo(50, 40)
        ..lineTo(83, 40)
        ..quadraticBezierTo(88, 40, 88, 45)
        ..lineTo(88, 77)
        ..quadraticBezierTo(88, 83, 82, 83)
        ..lineTo(18, 83)
        ..quadraticBezierTo(12, 83, 12, 77)
        ..lineTo(12, 35)
        ..quadraticBezierTo(12, 29, 17, 29)
        ..close();
      canvas.drawPath(outline, stroke);
    });
  }

  @override
  bool shouldRepaint(covariant _FolderOutlinePainter oldDelegate) =>
      color != oldDelegate.color;
}

class _FolderDecorationPainter extends CustomPainter {
  const _FolderDecorationPainter(this.shape, this.color);

  final FolderCoverShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    _paintFolderLineArt(canvas, size, color, (stroke) {
      switch (shape) {
        case FolderCoverShape.folder:
          break;
        case FolderCoverShape.star:
          final star = Path();
          for (var index = 0; index < 10; index++) {
            final angle = -math.pi / 2 + index * math.pi / 5;
            final radius = index.isEven ? 14.0 : 6.0;
            final x = 50 + radius * math.cos(angle);
            final y = 62 + radius * math.sin(angle);
            if (index == 0) {
              star.moveTo(x, y);
            } else {
              star.lineTo(x, y);
            }
          }
          canvas.drawPath(star..close(), stroke);
        case FolderCoverShape.heart:
          final heart = Path()
            ..moveTo(50, 75)
            ..cubicTo(46, 71, 36, 65, 36, 57)
            ..cubicTo(36, 49, 45, 48, 50, 55)
            ..cubicTo(55, 48, 64, 49, 64, 57)
            ..cubicTo(64, 65, 54, 71, 50, 75)
            ..close();
          canvas.drawPath(heart, stroke);
        case FolderCoverShape.flower:
          for (var index = 0; index < 5; index++) {
            final angle = index * 2 * math.pi / 5;
            canvas.save();
            canvas.translate(50, 62);
            canvas.rotate(angle);
            canvas.drawOval(
              Rect.fromCenter(
                center: const Offset(0, -9),
                width: 11,
                height: 16,
              ),
              stroke,
            );
            canvas.restore();
          }
          canvas.drawCircle(const Offset(50, 62), 3.5, stroke);
        case FolderCoverShape.sparkle:
          void sparkle(double x, double y, double radius) {
            final spark = Path()
              ..moveTo(x, y - radius)
              ..quadraticBezierTo(
                x + radius * 0.23,
                y - radius * 0.23,
                x + radius,
                y,
              )
              ..quadraticBezierTo(
                x + radius * 0.23,
                y + radius * 0.23,
                x,
                y + radius,
              )
              ..quadraticBezierTo(
                x - radius * 0.23,
                y + radius * 0.23,
                x - radius,
                y,
              )
              ..quadraticBezierTo(
                x - radius * 0.23,
                y - radius * 0.23,
                x,
                y - radius,
              )
              ..close();
            canvas.drawPath(spark, stroke);
          }

          sparkle(48, 62, 13);
          sparkle(65, 50, 4);
      }
    });
  }

  @override
  bool shouldRepaint(covariant _FolderDecorationPainter oldDelegate) =>
      shape != oldDelegate.shape || color != oldDelegate.color;
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
                                                      contents: controller.items
                                                          .where(
                                                            (item) =>
                                                                item.folder ==
                                                                folders[index],
                                                          ),
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
    required this.contents,
    required this.cover,
    required this.onTap,
    required this.onEdit,
    required this.onRename,
    required this.onDelete,
  });

  final String name;
  final Iterable<Notebook> contents;
  final FolderCoverStyle cover;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final darkMode = theme.brightness == Brightness.dark;
    final base = AppColors.displayInkColor(
      dominantFolderColor(contents),
      darkMode: darkMode,
    );
    final background = Color.lerp(
      darkMode ? AppColors.darkPaper : AppColors.paper,
      base,
      0.24,
    )!;
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: base.withValues(alpha: 0.25)),
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
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            PopupMenuButton<int>(
              tooltip: 'Actions for $title',
              icon: const Icon(Icons.more_horiz_rounded, size: 19),
              padding: EdgeInsets.zero,
              onSelected: onAction,
              itemBuilder: (_) => actions,
            ),
          ],
        ),
        const SizedBox(height: 7),
        Expanded(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(16),
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
                        size: 30,
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
                        backgroundColor: color,
                        child: iconColor == color
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
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
                    const <Color>[],
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
