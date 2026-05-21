import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart' as quill_delta;
import 'package:provider/provider.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/resizable_frame.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/image_block.dart';
import '../../../notebook/domain/note_page.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';

class PageOverlay extends StatelessWidget {
  const PageOverlay({
    required this.controller,
    this.interactionEnabled = true,
    this.worldOrigin = Offset.zero,
    this.page,
    this.pageIndex,
    this.renderBackground = true,
    this.renderActive = true,
    this.renderInactive = true,
    super.key,
  });

  final EditorController controller;
  final bool interactionEnabled;
  final Offset worldOrigin;
  final NotePage? page;
  final int? pageIndex;
  final bool renderBackground;
  final bool renderActive;
  final bool renderInactive;

  @override
  Widget build(BuildContext context) {
    final effectivePageIndex = pageIndex ?? controller.currentPageIndex;
    final effectivePage = page ?? controller.pageAt(effectivePageIndex);
    final tool = controller.tool;
    final activeTextId = controller.activeTextBlockId;
    final activeImageId = controller.activeImageBlockId;

    return IgnorePointer(
      ignoring: tool.isInk || !interactionEnabled,
      child: Stack(
        children: [
          if (renderBackground)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapDown: (details) async {
                  if (controller.consumeBackgroundTapSuppression()) {
                    return;
                  }
                  if (controller.activeTextBlockId != null ||
                      controller.activeImageBlockId != null ||
                      controller.lassoSelection != null) {
                    controller.clearActiveTextBlock();
                    controller.clearActiveImageBlock();
                    controller.clearLassoSelection();
                    return;
                  }
                  if (tool == DrawingTool.text || tool == DrawingTool.image) {
                    final message = await controller.handleTapOnPage(
                      effectivePageIndex,
                      details.localPosition + worldOrigin,
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
          for (final block in effectivePage.textBlocks)
            if ((block.id == activeTextId && renderActive) ||
                (block.id != activeTextId && renderInactive))
              _TextBlockWidget(
                block: block,
                pageIndex: effectivePageIndex,
                worldOrigin: worldOrigin,
                interactionEnabled: interactionEnabled,
              ),
          for (final block in effectivePage.imageBlocks)
            if ((block.id == activeImageId && renderActive) ||
                (block.id != activeImageId && renderInactive))
              _ImageBlockWidget(
                block: block,
                pageIndex: effectivePageIndex,
                worldOrigin: worldOrigin,
                interactionEnabled: interactionEnabled,
              ),
          if (renderActive &&
              controller.lassoSelection?.pageIndex == effectivePageIndex)
            _LassoSelectionWidget(
              selection: controller.lassoSelection!,
              pageIndex: effectivePageIndex,
              worldOrigin: worldOrigin,
              interactionEnabled: interactionEnabled,
            ),
        ],
      ),
    );
  }
}

class DocumentPageOverlay extends StatelessWidget {
  const DocumentPageOverlay({
    required this.controller,
    required this.pages,
    required this.pageSize,
    required this.pageGap,
    this.interactionEnabled = true,
    this.worldOrigin = Offset.zero,
    this.renderBackground = true,
    this.renderActive = true,
    this.renderInactive = true,
    super.key,
  });

  final EditorController controller;
  final List<NotePage> pages;
  final Size pageSize;
  final double pageGap;
  final bool interactionEnabled;
  final Offset worldOrigin;
  final bool renderBackground;
  final bool renderActive;
  final bool renderInactive;

  @override
  Widget build(BuildContext context) {
    final stride = pageSize.height + pageGap;
    return Stack(
      children: [
        for (var i = 0; i < pages.length; i++)
          Positioned(
            left: 0,
            top: i * stride,
            width: pageSize.width,
            height: pageSize.height,
            child: PageOverlay(
              controller: controller,
              interactionEnabled: interactionEnabled,
              worldOrigin: worldOrigin + Offset(0, i * stride),
              page: pages[i],
              pageIndex: i,
              renderBackground: renderBackground,
              renderActive: renderActive,
              renderInactive: renderInactive,
            ),
          ),
      ],
    );
  }
}

class _TextBlockWidget extends StatefulWidget {
  const _TextBlockWidget({
    required this.block,
    required this.pageIndex,
    required this.worldOrigin,
    required this.interactionEnabled,
  });

  final TextBlock block;
  final int pageIndex;
  final Offset worldOrigin;
  final bool interactionEnabled;

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
    final hasDeltaChange =
        widget.block.deltaJson != null &&
        widget.block.deltaJson != _lastDeltaJson;
    final hasTextChange =
        widget.block.deltaJson == null &&
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
    final canEdit =
        controller.tool == DrawingTool.text && widget.interactionEnabled;
    final canTransform = !controller.tool.isInk && widget.interactionEnabled;
    _quillController.readOnly = !(isActive && canEdit);

    if (isActive &&
        controller.activeTextController != _quillController &&
        canEdit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          controller.setActiveTextBlock(widget.block.id, _quillController);
          _focusNode.requestFocus();
        }
      });
    }

    return Positioned(
      left: widget.block.position.dx - widget.worldOrigin.dx,
      top: widget.block.position.dy - widget.worldOrigin.dy,
      child: IgnorePointer(
        ignoring: !canTransform,
        child: Builder(
          builder: (context) {
            return GestureDetector(
              onTapDown: canTransform
                  ? (_) {
                      if (controller.currentPageIndex != widget.pageIndex) {
                        controller.setCurrentPage(widget.pageIndex);
                      }
                      controller.markTextTap();
                      controller.setActiveTextBlock(
                        widget.block.id,
                        canEdit ? _quillController : null,
                      );
                      if (canEdit) {
                        _focusNode.requestFocus();
                      }
                    }
                  : null,
              onPanStart: canTransform
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
              onPanUpdate: canTransform
                  ? (details) {
                      if (!_dragFromFrame) {
                        return;
                      }
                      _updateMove(details.globalPosition, controller);
                    }
                  : null,
              onPanEnd: canTransform
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
                  Stack(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        constraints: BoxConstraints(
                          maxWidth: widget.block.width,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.paper.withValues(
                            alpha: isActive ? 0.85 : 0.0,
                          ),
                          borderRadius: BorderRadius.zero,
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
                    ],
                  ),
                  if (isActive && canTransform)
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
    final right = local.dx >= size.width - (_handleLineLength + _handleHitSize);
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
    final delta = _globalDeltaToLocalDelta(
      context,
      start: _dragStart!,
      end: globalPosition,
    );
    controller.updateTextBlockPositionOnPage(
      widget.pageIndex,
      widget.block.id,
      _startPosition! + delta,
    );
  }

  void _endMove(EditorController controller) {
    if (_dragStart == null || _startPosition == null) {
      return;
    }
    final current = controller.findTextBlockById(widget.block.id)?.position;
    if (current != null) {
      controller.commitTextMoveOnPage(
        widget.pageIndex,
        widget.block.id,
        _startPosition!,
        current,
      );
    }
    _dragStart = null;
    _startPosition = null;
    _dragFromFrame = false;
  }

  KeyEventResult? _handleKeyPressed(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return null;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      _editorController.deleteTextBlockOnPage(
        widget.pageIndex,
        widget.block.id,
      );
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
      final current = _editorController.findTextBlockById(widget.block.id);
      if (current == null) {
        return;
      }
      final deltaJson = jsonEncode(
        _quillController.document.toDelta().toJson(),
      );
      _lastDeltaJson = deltaJson;
      final plain = _quillController.document.toPlainText();
      _editorController.updateTextBlockContentOnPage(
        widget.pageIndex,
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
      } catch (e) {
        debugPrint('_TextBlockWidget: failed to decode Quill delta: $e');
      }
    }
    final delta = quill_delta.Delta();
    if (block.text.isNotEmpty) {
      delta.insert(block.text, <String, dynamic>{
        'size': block.fontSize.toInt().toString(),
        'color': _colorToHex(block.color),
      });
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
  const _ImageBlockWidget({
    required this.block,
    required this.pageIndex,
    required this.worldOrigin,
    required this.interactionEnabled,
  });

  final ImageBlock block;
  final int pageIndex;
  final Offset worldOrigin;
  final bool interactionEnabled;

  @override
  State<_ImageBlockWidget> createState() => _ImageBlockWidgetState();
}

class _ImageBlockWidgetState extends State<_ImageBlockWidget> {
  Offset? _dragStart;
  Offset? _startPosition;
  Offset? _resizeStart;
  Size? _startSize;
  ImageBlock? _resizeBefore;
  double? _startCropLeft;
  double? _startCropTop;
  double? _startCropRight;
  double? _startCropBottom;
  ResizeDirection? _activeResizeDirection;
  String? _loadedImageSizePath;
  Size? _loadedImageSize;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
  }

  @override
  void didUpdateWidget(covariant _ImageBlockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.path != widget.block.path) {
      _loadedImageSizePath = null;
      _loadedImageSize = null;
      _loadImageSize();
    } else {
      _normalizeBlockToImageBounds();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final canTransform = !controller.tool.isInk && widget.interactionEnabled;
    final isSelected = controller.activeImageBlockId == widget.block.id;
    final cropLeft = widget.block.cropLeft;
    final cropTop = widget.block.cropTop;
    final cropRight = widget.block.cropRight;
    final cropBottom = widget.block.cropBottom;
    final widthFactor = (cropRight - cropLeft).clamp(0.08, 1.0);
    final heightFactor = (cropBottom - cropTop).clamp(0.08, 1.0);
    final visibleWidth = widget.block.width * widthFactor;
    final visibleHeight = widget.block.height * heightFactor;
    final displayPosition = widget.block.position.translate(
      widget.block.width * cropLeft,
      widget.block.height * cropTop,
    );

    final double extraHitArea = isSelected ? 32.0 : 0.0;

    return Positioned(
      left: displayPosition.dx - widget.worldOrigin.dx - extraHitArea,
      top: displayPosition.dy - widget.worldOrigin.dy - extraHitArea,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (controller.currentPageIndex != widget.pageIndex) {
            controller.setCurrentPage(widget.pageIndex);
          }
          controller.clearActiveTextBlock();
          controller.setActiveImageBlock(widget.block.id);
        },
        onSecondaryTapDown: (details) =>
            _showImageContextMenu(context, details.globalPosition, controller),
        onDoubleTap: () => _editOcr(context, controller),
        onPanStart: canTransform
            ? (details) {
                _dragStart = details.globalPosition;
                _startPosition = widget.block.position;
              }
            : null,
        onPanUpdate: canTransform
            ? (details) {
                if (_dragStart == null || _startPosition == null) {
                  return;
                }
                final delta = _globalDeltaToLocalDelta(
                  context,
                  start: _dragStart!,
                  end: details.globalPosition,
                );
                controller.updateImageBlockPositionOnPage(
                  widget.pageIndex,
                  widget.block.id,
                  _startPosition! + delta,
                );
              }
            : null,
        onPanEnd: canTransform
            ? (_) {
                if (_dragStart == null || _startPosition == null) {
                  return;
                }
                final current = controller
                    .findImageBlockById(widget.block.id)
                    ?.position;
                if (current != null) {
                  controller.finalizeImageMoveOnPage(
                    widget.pageIndex,
                    widget.block.id,
                    _startPosition!,
                    current,
                  );
                }
                _dragStart = null;
                _startPosition = null;
              }
            : null,
        child: Container(
          padding: EdgeInsets.all(extraHitArea),
          color: isSelected ? Colors.transparent : null,
          child: ResizableFrame(
            isSelected: isSelected && canTransform,
            onResizeStart: _startResize,
            onResizeUpdate: (direction, delta) =>
                _updateResize(direction, delta, controller),
            onResizeEnd: (_) => _endResize(controller),
            child: Container(
              width: visibleWidth,
              height: visibleHeight,
              decoration: BoxDecoration(
                color: AppColors.toolbar,
                borderRadius: BorderRadius.zero,
                border: Border.all(
                  color: isSelected ? AppColors.inkBlack : AppColors.divider,
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _imageChild(
                      cropLeft: cropLeft,
                      cropTop: cropTop,
                      cropRight: cropRight,
                      cropBottom: cropBottom,
                      fullWidth: widget.block.width,
                      fullHeight: widget.block.height,
                      visibleWidth: visibleWidth,
                      visibleHeight: visibleHeight,
                      anchor: _anchorForDirection(_activeResizeDirection),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _imageChild({
    required double cropLeft,
    required double cropTop,
    required double cropRight,
    required double cropBottom,
    required double fullWidth,
    required double fullHeight,
    required double visibleWidth,
    required double visibleHeight,
    required _CropAnchor anchor,
  }) {
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
    final offsetX = _cropOffsetX(
      anchor: anchor,
      cropLeft: cropLeft,
      cropRight: cropRight,
      fullWidth: fullWidth,
      visibleWidth: visibleWidth,
    );
    final offsetY = _cropOffsetY(
      anchor: anchor,
      cropTop: cropTop,
      cropBottom: cropBottom,
      fullHeight: fullHeight,
      visibleHeight: visibleHeight,
    );
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: fullWidth,
        maxWidth: fullWidth,
        minHeight: fullHeight,
        maxHeight: fullHeight,
        child: Transform.translate(
          offset: Offset(offsetX, offsetY),
          child: SizedBox(
            width: fullWidth,
            height: fullHeight,
            child: Image.file(file, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }

  Future<void> _loadImageSize() async {
    final path = widget.block.path;
    if (path.isEmpty || path == _loadedImageSizePath) {
      if (path.isEmpty && widget.block.bytes != null) {
        if (!mounted) return;
        context.read<EditorController>().restoreImageCache(
          widget.pageIndex,
          widget.block.id,
        );
      }
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      if (widget.block.bytes != null) {
        if (!mounted) return;
        context.read<EditorController>().restoreImageCache(
          widget.pageIndex,
          widget.block.id,
        );
      }
      return;
    }
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      codec.dispose();
      if (!mounted || widget.block.path != path) {
        return;
      }
      setState(() {
        _loadedImageSizePath = path;
        _loadedImageSize = size;
      });
      _normalizeBlockToImageBounds();
    } catch (e) {
      debugPrint('_ImageBlockWidget: failed to load image bounds: $e');
    }
  }

  void _normalizeBlockToImageBounds() {
    final imageSize = _loadedImageSize;
    if (imageSize == null ||
        widget.block.cropLeft != 0.0 ||
        widget.block.cropTop != 0.0 ||
        widget.block.cropRight != 1.0 ||
        widget.block.cropBottom != 1.0) {
      return;
    }
    final blockSize = Size(widget.block.width, widget.block.height);
    final fitted = applyBoxFit(BoxFit.contain, imageSize, blockSize);
    final fittedSize = fitted.destination;
    final inset = Offset(
      (blockSize.width - fittedSize.width) / 2,
      (blockSize.height - fittedSize.height) / 2,
    );
    if (inset.distance < 0.5 &&
        (fittedSize.width - blockSize.width).abs() < 0.5 &&
        (fittedSize.height - blockSize.height).abs() < 0.5) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.block.path != _loadedImageSizePath) {
        return;
      }
      context.read<EditorController>().updateImageBlockOnPage(
        widget.pageIndex,
        widget.block.copyWith(
          position: widget.block.position + inset,
          width: fittedSize.width,
          height: fittedSize.height,
        ),
      );
    });
  }

  void _startResize(ResizeDirection direction) {
    _resizeStart = Offset.zero;
    _startSize = Size(widget.block.width, widget.block.height);
    _resizeBefore = widget.block;
    _startCropLeft = widget.block.cropLeft;
    _startCropTop = widget.block.cropTop;
    _startCropRight = widget.block.cropRight;
    _startCropBottom = widget.block.cropBottom;
    _activeResizeDirection = direction;
  }

  void _updateResize(
    ResizeDirection direction,
    Offset delta,
    EditorController controller,
  ) {
    if (_resizeStart == null || _startSize == null || _resizeBefore == null) {
      return;
    }
    _resizeStart = _resizeStart! + delta;
    final totalDelta = _resizeStart!;

    final baseWidth = _startSize!.width;
    final baseHeight = _startSize!.height;
    final ratio = baseHeight == 0 ? 1.0 : baseWidth / baseHeight;
    final before = _resizeBefore!;

    final isCorner =
        direction == ResizeDirection.topLeft ||
        direction == ResizeDirection.topRight ||
        direction == ResizeDirection.bottomLeft ||
        direction == ResizeDirection.bottomRight;

    if (isCorner) {
      final deltaValue = _cornerDelta(direction, totalDelta);
      final size = _clampSize(
        baseWidth: baseWidth,
        baseHeight: baseHeight,
        ratio: ratio,
        deltaValue: deltaValue,
      );
      final nextPosition = _cornerPosition(
        before,
        size,
        direction,
        cropLeft: _startCropLeft ?? before.cropLeft,
        cropTop: _startCropTop ?? before.cropTop,
        cropRight: _startCropRight ?? before.cropRight,
        cropBottom: _startCropBottom ?? before.cropBottom,
      );
      controller.updateImageBlockOnPage(
        widget.pageIndex,
        before.copyWith(
          position: nextPosition,
          width: size.width,
          height: size.height,
        ),
      );
      return;
    }

    const minVisible = 0.08;
    final cropLeft = _startCropLeft ?? before.cropLeft;
    final cropRight = _startCropRight ?? before.cropRight;
    final cropTop = _startCropTop ?? before.cropTop;
    final cropBottom = _startCropBottom ?? before.cropBottom;

    double nextCropLeft = cropLeft;
    double nextCropRight = cropRight;
    double nextCropTop = cropTop;
    double nextCropBottom = cropBottom;

    if (direction == ResizeDirection.centerLeft) {
      nextCropLeft = (cropLeft + totalDelta.dx / baseWidth).clamp(
        0.0,
        cropRight - minVisible,
      );
    } else if (direction == ResizeDirection.centerRight) {
      nextCropRight = (cropRight + totalDelta.dx / baseWidth).clamp(
        cropLeft + minVisible,
        1.0,
      );
    } else if (direction == ResizeDirection.topCenter) {
      nextCropTop = (cropTop + totalDelta.dy / baseHeight).clamp(
        0.0,
        cropBottom - minVisible,
      );
    } else if (direction == ResizeDirection.bottomCenter) {
      nextCropBottom = (cropBottom + totalDelta.dy / baseHeight).clamp(
        cropTop + minVisible,
        1.0,
      );
    }

    controller.updateImageBlockOnPage(
      widget.pageIndex,
      before.copyWith(
        cropLeft: nextCropLeft,
        cropTop: nextCropTop,
        cropRight: nextCropRight,
        cropBottom: nextCropBottom,
      ),
    );
  }

  double _cornerDelta(ResizeDirection direction, Offset delta) {
    double localDx;
    double localDy;
    switch (direction) {
      case ResizeDirection.topLeft:
        localDx = -delta.dx;
        localDy = -delta.dy;
        break;
      case ResizeDirection.topRight:
        localDx = delta.dx;
        localDy = -delta.dy;
        break;
      case ResizeDirection.bottomLeft:
        localDx = -delta.dx;
        localDy = delta.dy;
        break;
      case ResizeDirection.bottomRight:
        localDx = delta.dx;
        localDy = delta.dy;
        break;
      default:
        return 0.0;
    }

    return localDx.abs() >= localDy.abs() ? localDx : localDy;
  }

  Size _clampSize({
    required double baseWidth,
    required double baseHeight,
    required double ratio,
    required double deltaValue,
  }) {
    const minWidth = 80.0;
    const minHeight = 60.0;
    const maxWidth = 4096.0;
    const maxHeight = 4096.0;

    var nextWidth = baseWidth + deltaValue;
    var nextHeight = ratio == 0 ? baseHeight : nextWidth / ratio;

    if (nextWidth < minWidth) {
      nextWidth = minWidth;
      nextHeight = ratio == 0 ? baseHeight : nextWidth / ratio;
    }
    if (nextWidth > maxWidth) {
      nextWidth = maxWidth;
      nextHeight = ratio == 0 ? baseHeight : nextWidth / ratio;
    }
    if (nextHeight < minHeight) {
      nextHeight = minHeight;
      nextWidth = nextHeight * ratio;
    }
    if (nextHeight > maxHeight) {
      nextHeight = maxHeight;
      nextWidth = nextHeight * ratio;
    }

    return Size(nextWidth, nextHeight);
  }

  Offset _cornerPosition(
    ImageBlock before,
    Size nextSize,
    ResizeDirection direction, {
    required double cropLeft,
    required double cropTop,
    required double cropRight,
    required double cropBottom,
  }) {
    final baseWidth = _startSize?.width ?? before.width;
    final baseHeight = _startSize?.height ?? before.height;
    final visibleLeft = before.position.dx + cropLeft * baseWidth;
    final visibleTop = before.position.dy + cropTop * baseHeight;
    final visibleRight = before.position.dx + cropRight * baseWidth;
    final visibleBottom = before.position.dy + cropBottom * baseHeight;
    final nextLeft = visibleRight - cropRight * nextSize.width;
    final nextTop = visibleBottom - cropBottom * nextSize.height;
    final nextRight = visibleLeft - cropLeft * nextSize.width;
    final nextBottom = visibleTop - cropTop * nextSize.height;
    switch (direction) {
      case ResizeDirection.topLeft:
        return Offset(nextLeft, nextTop);
      case ResizeDirection.topRight:
        return Offset(nextRight, nextTop);
      case ResizeDirection.bottomLeft:
        return Offset(nextLeft, nextBottom);
      case ResizeDirection.bottomRight:
      default:
        return Offset(nextRight, nextBottom);
    }
  }

  void _endResize(EditorController controller) {
    final before = _resizeBefore;
    if (before != null) {
      final current = controller.findImageBlockById(widget.block.id);
      if (current != null) {
        controller.commitImageResizeOnPage(widget.pageIndex, before, current);
      }
    }
    _resizeStart = null;
    _startSize = null;
    _resizeBefore = null;
    _activeResizeDirection = null;
  }

  _CropAnchor _anchorForDirection(ResizeDirection? direction) {
    if (direction == null) {
      return const _CropAnchor(x: _CropAnchorAxis.left, y: _CropAnchorAxis.top);
    }
    switch (direction) {
      case ResizeDirection.topCenter:
        return const _CropAnchor(
          x: _CropAnchorAxis.left,
          y: _CropAnchorAxis.bottom,
        );
      case ResizeDirection.bottomCenter:
        return const _CropAnchor(
          x: _CropAnchorAxis.left,
          y: _CropAnchorAxis.top,
        );
      case ResizeDirection.centerLeft:
        return const _CropAnchor(
          x: _CropAnchorAxis.right,
          y: _CropAnchorAxis.top,
        );
      case ResizeDirection.centerRight:
        return const _CropAnchor(
          x: _CropAnchorAxis.left,
          y: _CropAnchorAxis.top,
        );
      case ResizeDirection.topLeft:
        return const _CropAnchor(
          x: _CropAnchorAxis.right,
          y: _CropAnchorAxis.bottom,
        );
      case ResizeDirection.topRight:
        return const _CropAnchor(
          x: _CropAnchorAxis.left,
          y: _CropAnchorAxis.bottom,
        );
      case ResizeDirection.bottomLeft:
        return const _CropAnchor(
          x: _CropAnchorAxis.right,
          y: _CropAnchorAxis.top,
        );
      case ResizeDirection.bottomRight:
        return const _CropAnchor(
          x: _CropAnchorAxis.left,
          y: _CropAnchorAxis.top,
        );
    }
  }

  double _cropOffsetX({
    required _CropAnchor anchor,
    required double cropLeft,
    required double cropRight,
    required double fullWidth,
    required double visibleWidth,
  }) {
    if (anchor.x == _CropAnchorAxis.right) {
      return visibleWidth - cropRight * fullWidth;
    }
    return -cropLeft * fullWidth;
  }

  double _cropOffsetY({
    required _CropAnchor anchor,
    required double cropTop,
    required double cropBottom,
    required double fullHeight,
    required double visibleHeight,
  }) {
    if (anchor.y == _CropAnchorAxis.bottom) {
      return visibleHeight - cropBottom * fullHeight;
    }
    return -cropTop * fullHeight;
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
                          final message = await controller.runOcrForImageOnPage(
                            widget.pageIndex,
                            widget.block,
                          );
                          if (message != null && context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(message)));
                          }
                          final updatedBlock = controller.findImageBlockById(
                            widget.block.id,
                          );
                          textController.text = updatedBlock?.ocrText ?? '';
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
    controller.updateImageBlockOcrTextOnPage(
      widget.pageIndex,
      widget.block.id,
      updated,
    );
  }

  Future<void> _showImageContextMenu(
    BuildContext context,
    Offset globalPosition,
    EditorController controller,
  ) async {
    if (controller.currentPageIndex != widget.pageIndex) {
      controller.setCurrentPage(widget.pageIndex);
    }
    controller.clearActiveTextBlock();
    controller.setActiveImageBlock(widget.block.id);

    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return;
    }

    final choice = await showMenu<_ImageContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(
          value: _ImageContextAction.copy,
          child: Text('Copy image'),
        ),
      ],
    );

    if (!context.mounted) {
      return;
    }

    if (choice == _ImageContextAction.copy) {
      final message = await controller.copyActiveImageToClipboard();
      if (!context.mounted) {
        return;
      }
      if (message != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }
}

class _LassoSelectionWidget extends StatefulWidget {
  const _LassoSelectionWidget({
    required this.selection,
    required this.pageIndex,
    required this.worldOrigin,
    required this.interactionEnabled,
  });

  final LassoSelection selection;
  final int pageIndex;
  final Offset worldOrigin;
  final bool interactionEnabled;

  @override
  State<_LassoSelectionWidget> createState() => _LassoSelectionWidgetState();
}

class _LassoSelectionWidgetState extends State<_LassoSelectionWidget> {
  Offset? _dragStartPos;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final rect = widget.selection.bounds.shift(widget.selection.delta);

    return Positioned(
      left: rect.left + widget.worldOrigin.dx,
      top: rect.top + widget.worldOrigin.dy,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: widget.interactionEnabled
            ? (details) {
                _dragStartPos = details.globalPosition;
              }
            : null,
        onPanUpdate: widget.interactionEnabled
            ? (details) {
                if (_dragStartPos == null) return;
                final start = _dragStartPos!;
                final current = details.globalPosition;
                final localDelta = _globalDeltaToLocalDelta(
                  context,
                  start: start,
                  end: current,
                );

                _dragStartPos = current;
                controller.updateLassoMove(widget.selection.delta + localDelta);
              }
            : null,
        onPanEnd: widget.interactionEnabled
            ? (_) {
                _dragStartPos = null;
                controller.commitLassoMove();
              }
            : null,
        onPanCancel: widget.interactionEnabled
            ? () {
                _dragStartPos = null;
                controller.commitLassoMove();
              }
            : null,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.blue,
                  width: 1.5,
                  style: BorderStyle.solid,
                ),
                color: const Color(0x112196F3),
              ),
            ),
            if (widget.interactionEnabled)
              Positioned(
                top: -20,
                right: -20,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Material(
                      type: MaterialType.circle,
                      color: AppColors.paper,
                      elevation: 2,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () async {
                          final message = await controller
                              .copyActiveElementToClipboard();
                          if (!context.mounted) return;
                          if (message != null) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(message)));
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied selection')),
                            );
                            controller.clearLassoSelection();
                          }
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Icon(Icons.copy, size: 18, color: Colors.blue),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      type: MaterialType.circle,
                      color: AppColors.paper,
                      elevation: 2,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: controller.deleteLassoSelection,
                        child: const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: Colors.red,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _CropAnchorAxis { left, right, top, bottom }

class _CropAnchor {
  const _CropAnchor({required this.x, required this.y});

  final _CropAnchorAxis x;
  final _CropAnchorAxis y;
}

enum _ImageContextAction { copy }

Offset _globalDeltaToLocalDelta(
  BuildContext context, {
  required Offset start,
  required Offset end,
}) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox) {
    return end - start;
  }
  final transform = Matrix4.copy(renderObject.getTransformTo(null));
  final determinant = transform.invert();
  if (determinant == 0) {
    return end - start;
  }
  return MatrixUtils.transformPoint(transform, end) -
      MatrixUtils.transformPoint(transform, start);
}
