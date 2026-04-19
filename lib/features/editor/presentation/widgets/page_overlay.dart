import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart' as quill_delta;
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
    return IgnorePointer(
      ignoring: tool.isInk,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (details) async {
                if (controller.consumeBackgroundTapSuppression()) {
                  return;
                }
                if (controller.activeTextBlockId != null) {
                  controller.clearActiveTextBlock();
                  return;
                }
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
      ),
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
  bool _dragFromFrame = false;
  static const double _handleLineLength = 12.0;
  static const double _handleDotRadius = 4.0;
  static const double _handleDotDiameter = _handleDotRadius * 2;
  static const double _handleHitSize = 28.0;
  bool _isHandleHovered = false;
  bool _isHandleDragging = false;
  late quill.QuillController _quillController;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<quill.DocChange>? _docSubscription;
  String? _lastDeltaJson;
  late EditorController _editorController;
  bool _isNormalizing = false;

  @override
  void initState() {
    super.initState();
    _initQuill();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editorController = context.read<EditorController>();
  }

  @override
  void didUpdateWidget(covariant _TextBlockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hasDeltaChange = widget.block.deltaJson != null &&
        widget.block.deltaJson != _lastDeltaJson;
    final hasTextChange = widget.block.deltaJson == null &&
        oldWidget.block.text != widget.block.text;
    if (hasDeltaChange || hasTextChange) {
      _initQuill();
    }
  }

  @override
  void dispose() {
    _docSubscription?.cancel();
    _scrollController.dispose();
    _focusNode.dispose();
    _quillController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final isActive = controller.activeTextBlockId == widget.block.id;
    final canDrag = controller.tool == DrawingTool.text;
    _quillController.readOnly = !isActive;

    if (isActive && controller.activeTextController != _quillController) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          controller.setActiveTextBlock(widget.block.id, _quillController);
          _focusNode.requestFocus();
        }
      });
    }

    return Positioned(
      left: widget.block.position.dx,
      top: widget.block.position.dy,
      child: IgnorePointer(
        ignoring: controller.tool != DrawingTool.text,
        child: Builder(
          builder: (context) {
            return GestureDetector(
              onTapDown: controller.tool == DrawingTool.text
                  ? (_) {
                      controller.markTextTap();
                      controller.setActiveTextBlock(
                        widget.block.id,
                        _quillController,
                      );
                      _focusNode.requestFocus();
                    }
                  : null,
              onPanStart: canDrag
                  ? (details) {
                      final box = context.findRenderObject() as RenderBox?;
                      final size = box?.size ?? Size.zero;
                      final local = details.localPosition;
                      _dragFromFrame = !isActive || _isOnFrame(local, size);
                      if (!_dragFromFrame) {
                        return;
                      }
                      _startMove(details.globalPosition);
                    }
                  : null,
              onPanUpdate: canDrag
                  ? (details) {
                      if (!_dragFromFrame) {
                        return;
                      }
                      _updateMove(details.globalPosition, controller);
                    }
                  : null,
              onPanEnd: canDrag
                  ? (_) {
                      if (!_dragFromFrame) {
                        return;
                      }
                      _endMove(controller);
                    }
                  : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    constraints: BoxConstraints(maxWidth: widget.block.width),
                    decoration: BoxDecoration(
                      color: AppColors.paper
                          .withValues(alpha: isActive ? 0.85 : 0.0),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isActive
                            ? AppColors.inkBlack
                            : Colors.transparent,
                        width: 1.2,
                      ),
                    ),
                    child: quill.QuillEditor(
                      controller: _quillController,
                      focusNode: _focusNode,
                      scrollController: _scrollController,
                      config: quill.QuillEditorConfig(
                        scrollable: false,
                        padding: EdgeInsets.zero,
                        autoFocus: false,
                        expands: false,
                        // ignore: experimental_member_use
                        onKeyPressed: (event, node) =>
                          _handleKeyPressed(event),
                      ),
                    ),
                  ),
                  if (isActive && canDrag)
                    SizedBox(
                      width: _handleLineLength + _handleDotDiameter,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _dragHandle(controller),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  bool _isOnFrame(Offset local, Size size) {
    const frameHit = 8.0;
    final left = local.dx <= frameHit;
    final right = local.dx >=
      size.width - (_handleLineLength + _handleHitSize);
    final top = local.dy <= frameHit;
    final bottom = local.dy >= size.height - frameHit;
    return left || right || top || bottom;
  }

  Widget _dragHandle(EditorController controller) {
    final handleColor = (_isHandleDragging || _isHandleHovered)
      ? AppColors.inkBlack
      : Colors.grey.shade500;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (details) {
        _dragFromFrame = true;
        setState(() => _isHandleDragging = true);
        _startMove(details.globalPosition);
      },
      onPanUpdate: (details) {
        _updateMove(details.globalPosition, controller);
      },
      onPanEnd: (_) {
        setState(() => _isHandleDragging = false);
        _endMove(controller);
      },
      onPanCancel: () {
        setState(() => _isHandleDragging = false);
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHandleHovered = true),
        onExit: (_) => setState(() => _isHandleHovered = false),
        child: SizedBox(
          width: _handleLineLength + _handleHitSize,
          height: _handleHitSize,
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: _handleLineLength,
                  height: 1.2,
                  color: handleColor,
                ),
                Container(
                  width: _handleDotRadius * 2,
                  height: _handleDotRadius * 2,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    border: Border.all(color: handleColor, width: 1.2),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _startMove(Offset globalPosition) {
    _dragStart = globalPosition;
    _startPosition = widget.block.position;
  }

  void _updateMove(Offset globalPosition, EditorController controller) {
    if (_dragStart == null || _startPosition == null) {
      return;
    }
    final delta = globalPosition - _dragStart!;
    controller.updateTextBlockPosition(
      widget.block.id,
      _startPosition! + delta,
    );
  }

  void _endMove(EditorController controller) {
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
    _dragFromFrame = false;
  }

  KeyEventResult? _handleKeyPressed(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return null;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      _editorController.deleteTextBlock(widget.block.id);
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.backspace) {
      return null;
    }
    return null;
  }

  void _initQuill() {
    final doc = _documentFromBlock(widget.block);
    final selectionOffset = doc.length > 0 ? doc.length - 1 : 0;
    _quillController = quill.QuillController(
      document: doc,
      selection: TextSelection.collapsed(offset: selectionOffset),
    );
    _lastDeltaJson = jsonEncode(doc.toDelta().toJson());
    _docSubscription?.cancel();
    _docSubscription = _quillController.document.changes.listen((event) {
      if (_isNormalizing) {
        return;
      }
      final rawText = _quillController.document.toPlainText();
      final trailingNewlines = _countTrailingNewlines(rawText);
      if (trailingNewlines > 2) {
        final deleteCount = trailingNewlines - 2;
        final deleteStart = rawText.length - deleteCount;
        _isNormalizing = true;
        Future.microtask(() {
          if (!mounted) {
            return;
          }
          _quillController.replaceText(
            deleteStart,
            deleteCount,
            '',
            TextSelection.collapsed(offset: deleteStart),
          );
          _isNormalizing = false;
        });
        return;
      }
      final current = _editorController.currentPage.textBlocks.firstWhere(
        (item) => item.id == widget.block.id,
      );
      final deltaJson = jsonEncode(
        _quillController.document.toDelta().toJson(),
      );
      _lastDeltaJson = deltaJson;
      final plain = _quillController.document.toPlainText();
      _editorController.updateTextBlockContent(
        current,
        plainText: plain,
        deltaJson: deltaJson,
      );
    });
  }

  quill.Document _documentFromBlock(TextBlock block) {
    final deltaJson = block.deltaJson;
    if (deltaJson != null && deltaJson.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(deltaJson);
        if (decoded is List) {
          return quill.Document.fromJson(decoded);
        }
      } catch (_) {}
    }
    final delta = quill_delta.Delta();
    if (block.text.isNotEmpty) {
      delta.insert(
        block.text,
        <String, dynamic>{
          'size': block.fontSize.toInt().toString(),
          'color': _colorToHex(block.color),
        },
      );
    }
    delta.insert('\n');
    return quill.Document.fromDelta(delta);
  }

  String _colorToHex(Color color) {
    final value = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${value.substring(2)}';
  }

  int _countTrailingNewlines(String text) {
    var count = 0;
    for (var i = text.length - 1; i >= 0; i--) {
      if (text[i] != '\n') {
        break;
      }
      count++;
    }
    return count;
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
    final canDrag = controller.tool == DrawingTool.image;

    return Positioned(
      left: widget.block.position.dx,
      top: widget.block.position.dy,
      child: GestureDetector(
        onTap: () => context.read<EditorController>().clearActiveTextBlock(),
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
