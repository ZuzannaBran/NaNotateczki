import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/image_block.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';

class PageOverlay extends StatelessWidget {
  const PageOverlay({required this.controller, super.key});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final tool = controller.tool;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (details) async {
              if (tool == DrawingTool.text || tool == DrawingTool.image) {
                final message = await controller.handleTap(
                  details.localPosition,
                );
                if (message != null && context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(message)));
                }
              }
            },
          ),
        ),
        for (final block in controller.currentPage.textBlocks)
          _TextBlockWidget(block: block),
        for (final block in controller.currentPage.imageBlocks)
          _ImageBlockWidget(block: block),
      ],
    );
  }
}

class _TextBlockWidget extends StatefulWidget {
  const _TextBlockWidget({required this.block});

  final TextBlock block;

  @override
  State<_TextBlockWidget> createState() => _TextBlockWidgetState();
}

class _TextBlockWidgetState extends State<_TextBlockWidget> {
  Offset? _dragStart;
  Offset? _startPosition;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<EditorController>();
    final canDrag =
        controller.tool == DrawingTool.lasso ||
        controller.tool == DrawingTool.text;

    return Positioned(
      left: widget.block.position.dx,
      top: widget.block.position.dy,
      child: GestureDetector(
        onDoubleTap: () => _editText(context, controller),
        onPanStart: canDrag
            ? (details) {
                _dragStart = details.globalPosition;
                _startPosition = widget.block.position;
              }
            : null,
        onPanUpdate: canDrag
            ? (details) {
                if (_dragStart == null || _startPosition == null) {
                  return;
                }
                final delta = details.globalPosition - _dragStart!;
                controller.updateTextBlockPosition(
                  widget.block.id,
                  _startPosition! + delta,
                );
              }
            : null,
        onPanEnd: canDrag
            ? (_) {
                if (_dragStart == null || _startPosition == null) {
                  return;
                }
                final current = controller.currentPage.textBlocks
                    .firstWhere((item) => item.id == widget.block.id)
                    .position;
                controller.commitTextMove(
                  widget.block.id,
                  _startPosition!,
                  current,
                );
                _dragStart = null;
                _startPosition = null;
              }
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          constraints: BoxConstraints(maxWidth: widget.block.width),
          decoration: BoxDecoration(
            color: AppColors.paper.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.block.text,
            style: TextStyle(
              fontSize: widget.block.fontSize,
              color: widget.block.color,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editText(
    BuildContext context,
    EditorController controller,
  ) async {
    final textController = TextEditingController(text: widget.block.text);
    final updated = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit text'),
          content: TextField(controller: textController, maxLines: 5),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(textController.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (updated == null || updated == widget.block.text) {
      return;
    }
    controller.updateTextBlockText(widget.block, updated);
  }
}

class _ImageBlockWidget extends StatefulWidget {
  const _ImageBlockWidget({required this.block});

  final ImageBlock block;

  @override
  State<_ImageBlockWidget> createState() => _ImageBlockWidgetState();
}

class _ImageBlockWidgetState extends State<_ImageBlockWidget> {
  Offset? _dragStart;
  Offset? _startPosition;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<EditorController>();
    final canDrag =
        controller.tool == DrawingTool.lasso ||
        controller.tool == DrawingTool.image;

    return Positioned(
      left: widget.block.position.dx,
      top: widget.block.position.dy,
      child: GestureDetector(
        onDoubleTap: () => _editOcr(context, controller),
        onPanStart: canDrag
            ? (details) {
                _dragStart = details.globalPosition;
                _startPosition = widget.block.position;
              }
            : null,
        onPanUpdate: canDrag
            ? (details) {
                if (_dragStart == null || _startPosition == null) {
                  return;
                }
                final delta = details.globalPosition - _dragStart!;
                controller.updateImageBlockPosition(
                  widget.block.id,
                  _startPosition! + delta,
                );
              }
            : null,
        onPanEnd: canDrag
            ? (_) {
                if (_dragStart == null || _startPosition == null) {
                  return;
                }
                final current = controller.currentPage.imageBlocks
                    .firstWhere((item) => item.id == widget.block.id)
                    .position;
                controller.commitImageMove(
                  widget.block.id,
                  _startPosition!,
                  current,
                );
                _dragStart = null;
                _startPosition = null;
              }
            : null,
        child: Container(
          width: widget.block.width,
          height: widget.block.height,
          decoration: BoxDecoration(
            color: AppColors.toolbar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.divider),
          ),
          child: _imageChild(),
        ),
      ),
    );
  }

  Widget _imageChild() {
    final path = widget.block.path;
    if (path.isEmpty) {
      return const Center(
        child: Icon(Icons.image_outlined, color: AppColors.inkBlack),
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      return const Center(
        child: Icon(Icons.broken_image_outlined, color: AppColors.inkBlack),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(file, fit: BoxFit.cover),
    );
  }

  Future<void> _editOcr(
    BuildContext context,
    EditorController controller,
  ) async {
    final textController = TextEditingController(text: widget.block.ocrText);
    final updated = await showDialog<String>(
      context: context,
      builder: (context) {
        var isRunning = false;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('OCR text'),
              content: TextField(controller: textController, maxLines: 5),
              actions: [
                TextButton(
                  onPressed: isRunning
                      ? null
                      : () async {
                          setState(() => isRunning = true);
                          final message = await controller.runOcrForImage(
                            widget.block,
                          );
                          if (message != null && context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(message)));
                          }
                          final updatedBlock = controller
                              .currentPage
                              .imageBlocks
                              .firstWhere((item) => item.id == widget.block.id);
                          textController.text = updatedBlock.ocrText;
                          setState(() => isRunning = false);
                        },
                  child: const Text('Run OCR'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(textController.text),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (updated == null || updated == widget.block.ocrText) {
      return;
    }
    controller.updateImageBlockOcrText(widget.block.id, updated);
  }
}
