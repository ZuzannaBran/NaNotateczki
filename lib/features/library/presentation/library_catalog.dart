import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
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
  final chosen = counts.entries.reduce(
    (a, b) => a.value >= b.value ? a : b,
  );
  return Color(chosen.key);
}

IconData folderCoverIcon(FolderCoverShape shape) {
  return switch (shape) {
    FolderCoverShape.folder => Icons.folder_rounded,
    FolderCoverShape.star => Icons.star_rounded,
    FolderCoverShape.heart => Icons.favorite_rounded,
    FolderCoverShape.flower => Icons.local_florist_rounded,
    FolderCoverShape.sparkle => Icons.auto_awesome_rounded,
  };
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

  @override
  Widget build(BuildContext context) {
    final activeFolder = folder;
    final folders = controller.folderNames;
    final notes = activeFolder == null
        ? <Notebook>[]
        : controller.items
              .where((item) => item.folder == activeFolder)
              .toList();
    final scheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 24, 28, 18),
            child: Row(
              children: [
                if (activeFolder != null) ...[
                  IconButton(
                    key: const ValueKey('catalog-back'),
                    tooltip: 'Back to projects',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    activeFolder ?? 'Library',
                    key: const ValueKey('catalog-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontFamily: 'Georgia',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (activeFolder != null)
                  IconButton(
                    tooltip: 'Edit folder cover',
                    onPressed: () => onEditFolder(activeFolder),
                    icon: const Icon(Icons.palette_outlined),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
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
                      return GridView.builder(
                        key: ValueKey(
                          activeFolder == null
                              ? 'catalog-folders'
                              : 'catalog-items:$activeFolder',
                        ),
                        padding: const EdgeInsets.all(30),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 224,
                              mainAxisExtent: 263,
                              mainAxisSpacing: 24,
                              crossAxisSpacing: 24,
                            ),
                        itemCount: activeFolder == null
                            ? folders.length
                            : notes.length,
                        itemBuilder: (context, index) {
                          if (activeFolder == null) {
                            final name = folders[index];
                            final contents = controller.items
                                .where((item) => item.folder == name);
                            return _FolderTile(
                              name: name,
                              contents: contents,
                              cover: controller.folderCoverFor(name),
                              onTap: () => onFolderTap(name),
                              onEdit: () => onEditFolder(name),
                              onRename: () => onRenameFolder(name),
                              onDelete: () => onDeleteFolder(name),
                            );
                          }
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
          Icon(icon, size: 52, color: AppColors.inkBlack),
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
    final base = dominantFolderColor(contents);
    final background = Color.lerp(AppColors.paper, base, 0.24)!;
    final iconColor = cover.iconColor ?? AppColors.inkBlack;
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
          child: Icon(
            folderCoverIcon(cover.shape),
            color: iconColor,
            size: 88,
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
        Expanded(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: child,
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
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
    final board = item.kind == NotebookKind.board;
    final bounds = board
        ? _boardPreviewBounds(page)
        : const Rect.fromLTWH(0, 0, 820, 1160);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
        boxShadow: const [
          BoxShadow(color: AppColors.shadow, blurRadius: 5),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: page == null
            ? Center(
                child: Icon(
                  board ? Icons.dashboard_outlined : Icons.description_outlined,
                  size: 46,
                  color: AppColors.divider,
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
                      const Positioned.fill(
                        child: ColoredBox(color: AppColors.paper),
                      ),
                      for (final image in page.imageBlocks)
                        _imagePreview(image, bounds),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _PagePreviewPainter(page, bounds.topLeft),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _imagePreview(ImageBlock block, Rect bounds) {
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
      preview = const ColoredBox(color: AppColors.toolbar);
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
    include(Rect.fromLTWH(
      image.position.dx,
      image.position.dy,
      math.max(1, image.width),
      math.max(1, image.height),
    ));
  }
  for (final block in page.textBlocks) {
    include(Rect.fromLTWH(
      block.position.dx,
      block.position.dy,
      math.max(1, block.width),
      math.max(36, block.fontSize * 3),
    ));
  }
  if (content == null) {
    return const Rect.fromLTWH(-400, -400, 800, 800);
  }
  final padded = content!.inflate(100);
  final side = math.max(600.0, math.max(padded.width, padded.height));
  return Rect.fromCenter(center: padded.center, width: side, height: side);
}

class _PagePreviewPainter extends CustomPainter {
  const _PagePreviewPainter(this.page, this.origin);

  final NotePage page;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(-origin.dx, -origin.dy);
    for (final stroke in page.inkStrokes) {
      if (stroke.tool.isEraser || stroke.points.isEmpty) {
        continue;
      }
      final ink = Paint()
        ..color = stroke.tool == DrawingTool.highlighter
            ? stroke.color.withValues(alpha: 0.42)
            : stroke.color
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
            color: block.color,
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
      !identical(page, oldDelegate.page) || origin != oldDelegate.origin;
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
              const Text('Cover shape'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final option in FolderCoverShape.values)
                    ChoiceChip(
                      key: ValueKey('cover-shape:${option.name}'),
                      label: Icon(folderCoverIcon(option)),
                      selected: shape == option,
                      onSelected: (_) => update(() => shape = option),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              const Text('Icon color'),
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
              TextButton(
                onPressed: () => update(() => iconColor = null),
                child: const Text('Default icon color'),
              ),
            ],
          ),
        ),
        actions: [
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
        ],
      ),
    ),
  );
  if (result != null) {
    await controller.updateFolderCover(folder, result);
  }
}
