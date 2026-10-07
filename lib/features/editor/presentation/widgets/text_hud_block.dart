import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';

import '../../../../core/input/soft_keyboard.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';
import '../interaction/object_transform_engine.dart';
import 'object_transform_hud.dart';

class TextHudBlock extends StatefulWidget {
  const TextHudBlock({
    required this.controller,
    required this.block,
    required this.pageIndex,
    required this.worldOrigin,
    required this.interactionEnabled,
    super.key,
  });

  final EditorController controller;
  final TextBlock block;
  final int pageIndex;
  final Offset worldOrigin;
  final bool interactionEnabled;

  @override
  State<TextHudBlock> createState() => _TextHudBlockState();
}

class _TextHudBlockState extends State<TextHudBlock> {
  static const double _frameMinHeight = 44;
  static const double _minTextWidth = 72;
  static const double _maxTextWidth = 1200;
  static const double _minTextFontSize = 8;
  static const double _maxTextFontSize = 96;

  final GlobalKey _contentKey = GlobalKey();
  late final TextEditingController _textController;
  final FocusNode _focusNode = FocusNode();

  double _frameHeight = _frameMinHeight;
  bool _metricsScheduled = false;
  bool _focusRequestScheduled = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.block.text);
  }

  @override
  void didUpdateWidget(covariant TextHudBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.id != widget.block.id ||
        (!_focusNode.hasFocus && _textController.text != widget.block.text)) {
      _textController.value = TextEditingValue(
        text: widget.block.text,
        selection: TextSelection.collapsed(offset: widget.block.text.length),
      );
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing =
        widget.controller.tool == DrawingTool.text &&
        widget.controller.activeTextBlockId == widget.block.id;
    _scheduleMetrics();

    if (isEditing) {
      _scheduleFocusRequest();
    } else if (_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focusNode.hasFocus) {
          _focusNode.unfocus();
        }
      });
    }

    final localPosition = widget.block.position - widget.worldOrigin;
    final rect = Rect.fromLTWH(
      localPosition.dx,
      localPosition.dy,
      widget.block.width,
      _frameHeight,
    );

    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _buildContent(isEditing),
          ObjectTransformHud<TextBlock>(
            key: ValueKey('object-hud-text-${widget.block.id}'),
            data: widget.block,
            rect: rect,
            rotation: widget.block.rotation,
            interactive: widget.interactionEnabled && !isEditing,
            showHandles: !isEditing,
            draggable: !isEditing,
            rotatable: !isEditing,
            enabledHandles: const {
              HandlePosition.topLeft,
              HandlePosition.topRight,
              HandlePosition.right,
              HandlePosition.bottomLeft,
              HandlePosition.bottomRight,
            },
            resizeModeResolver: (handle) {
              return handle.isDiagonal ? ResizeMode.scale : ResizeMode.freeform;
            },
            constraints: const BoxConstraints(
              minWidth: _minTextWidth,
              maxWidth: _maxTextWidth,
              minHeight: 1,
              maxHeight: 2400,
            ),
            onDoubleTap: _enterEditing,
            onPreview: _previewTransform,
            onCommit: _commitTransform,
            onCancel: _cancelTransform,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool isEditing) {
    final style = _styleFor(widget.block, widget.block.fontSize);
    final localPosition = widget.block.position - widget.worldOrigin;
    return Positioned(
      left: localPosition.dx,
      top: localPosition.dy,
      width: widget.block.width,
      child: Transform.rotate(
        angle: widget.block.rotation,
        alignment: Alignment.center,
        child: Container(
          key: _contentKey,
          width: widget.block.width,
          constraints: const BoxConstraints(minHeight: _frameMinHeight),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          color: Colors.transparent,
          child: IgnorePointer(
            ignoring: !isEditing,
            child: EditableText(
              controller: _textController,
              focusNode: _focusNode,
              readOnly: !isEditing,
              style: style.textStyle,
              cursorColor: Theme.of(context).colorScheme.primary,
              backgroundCursorColor: Colors.grey,
              textAlign: style.textAlign,
              maxLines: null,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              selectionColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.24),
              showSelectionHandles: isEditing,
              onChanged: _onTextChanged,
            ),
          ),
        ),
      ),
    );
  }

  void _enterEditing() {
    if (widget.controller.currentPageIndex != widget.pageIndex) {
      widget.controller.setCurrentPage(widget.pageIndex);
    }
    widget.controller.markTextTap();
    if (widget.controller.tool != DrawingTool.text) {
      widget.controller.setTool(DrawingTool.text);
    }
    widget.controller.setActiveTextBlock(widget.block.id, null);
    _requestFocus(selectPlaceholder: _textController.text == 'Text');
  }

  void _scheduleFocusRequest() {
    if (_focusNode.hasFocus || _focusRequestScheduled) {
      return;
    }
    _focusRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusRequestScheduled = false;
      if (!mounted ||
          widget.controller.tool != DrawingTool.text ||
          widget.controller.activeTextBlockId != widget.block.id) {
        return;
      }
      _requestFocus(selectPlaceholder: false);
    });
  }

  void _requestFocus({required bool selectPlaceholder}) {
    _focusNode.requestFocus();
    if (selectPlaceholder) {
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
    }
    requestSoftKeyboardForFocus(context, _focusNode);
  }

  void _onTextChanged(String value) {
    final current = widget.controller.findTextBlockById(widget.block.id);
    if (current == null) {
      return;
    }
    final deltaJson = _deltaJsonForText(
      current.deltaJson,
      value,
      fontSize: current.fontSize,
      color: current.color,
    );
    widget.controller.updateTextBlockContentOnPage(
      widget.pageIndex,
      current,
      plainText: value,
      deltaJson: deltaJson,
    );
    _scheduleMetrics();
  }

  void _previewTransform(TextBlock before, ObjectTransformSnapshot preview) {
    final scale =
        preview.kind == ObjectTransformKind.resize &&
            preview.handle?.isDiagonal == true &&
            before.width > 0
        ? preview.rect.width / before.width
        : 1.0;
    final nextFontSize = (before.fontSize * scale)
        .clamp(_minTextFontSize, _maxTextFontSize)
        .toDouble();
    final double actualScale = before.fontSize == 0
        ? 1.0
        : nextFontSize / before.fontSize;
    final nextDelta = (actualScale - 1).abs() <= 1e-6
        ? before.deltaJson
        : _scaledDeltaJson(
            before.deltaJson,
            scale: actualScale,
            fallbackSize: before.fontSize,
          );

    widget.controller.updateTextBlockOnPage(
      widget.pageIndex,
      before.copyWith(
        position: preview.rect.topLeft + widget.worldOrigin,
        width: preview.rect.width,
        fontSize: nextFontSize,
        rotation: preview.rotation,
        deltaJson: nextDelta,
      ),
    );
  }

  void _commitTransform(TextBlock before, ObjectTransformSnapshot preview) {
    final current = widget.controller.findTextBlockById(before.id);
    if (current == null) {
      return;
    }
    widget.controller.commitTextUpdateOnPage(widget.pageIndex, before, current);
  }

  void _cancelTransform(TextBlock before) {
    widget.controller.updateTextBlockOnPage(widget.pageIndex, before);
  }

  void _scheduleMetrics() {
    if (_metricsScheduled) {
      return;
    }
    _metricsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsScheduled = false;
      if (!mounted) {
        return;
      }
      final renderObject = _contentKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox) {
        return;
      }
      final measuredHeight = math.max(
        _frameMinHeight,
        renderObject.size.height,
      );
      if ((measuredHeight - _frameHeight).abs() <= 0.5) {
        return;
      }
      setState(() {
        _frameHeight = measuredHeight;
      });
    });
  }

  _TextHudStyle _styleFor(TextBlock block, double fontSize) {
    final inline = _firstInlineAttributes(block.deltaJson);
    final paragraph = _firstParagraphAttributes(block.deltaJson);
    final align = paragraph['align']?.toString();
    final decorations = <TextDecoration>[
      if (inline['underline'] == true) TextDecoration.underline,
      if (inline['strike'] == true) TextDecoration.lineThrough,
    ];

    return _TextHudStyle(
      textStyle: TextStyle(
        color: block.color,
        fontSize: fontSize,
        fontFamily: inline['font']?.toString(),
        fontWeight: inline['bold'] == true
            ? FontWeight.bold
            : FontWeight.normal,
        fontStyle: inline['italic'] == true
            ? FontStyle.italic
            : FontStyle.normal,
        decoration: decorations.isEmpty
            ? TextDecoration.none
            : TextDecoration.combine(decorations),
        height: 1.25,
      ),
      textAlign: switch (align) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'justify' => TextAlign.justify,
        _ => TextAlign.left,
      },
    );
  }

  Map<String, dynamic> _firstInlineAttributes(String? deltaJson) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return const <String, dynamic>{};
      }
      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }
        final op = Map<String, dynamic>.from(raw);
        final insert = op['insert'];
        if (insert is! String || insert.replaceAll('\n', '').isEmpty) {
          continue;
        }
        final attributes = op['attributes'];
        return attributes is Map
            ? Map<String, dynamic>.from(attributes)
            : const <String, dynamic>{};
      }
    } catch (_) {
      return const <String, dynamic>{};
    }
    return const <String, dynamic>{};
  }

  Map<String, dynamic> _firstParagraphAttributes(String? deltaJson) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return const <String, dynamic>{};
      }
      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }
        final op = Map<String, dynamic>.from(raw);
        final insert = op['insert'];
        if (insert is! String || !insert.contains('\n')) {
          continue;
        }
        final attributes = op['attributes'];
        return attributes is Map
            ? Map<String, dynamic>.from(attributes)
            : const <String, dynamic>{};
      }
    } catch (_) {
      return const <String, dynamic>{};
    }
    return const <String, dynamic>{};
  }

  String _deltaJsonForText(
    String? previousDeltaJson,
    String text, {
    required double fontSize,
    required Color color,
  }) {
    final inline = Map<String, dynamic>.from(
      _firstInlineAttributes(previousDeltaJson),
    );
    inline['size'] = fontSize.round().toString();
    inline['color'] = _colorToHex(color);
    final paragraph = Map<String, dynamic>.from(
      _firstParagraphAttributes(previousDeltaJson),
    );

    final operations = <Map<String, dynamic>>[];
    final normalized = text.replaceAll('\r', '');
    final lines = normalized.split('\n');
    for (final line in lines) {
      if (line.isNotEmpty) {
        operations.add(<String, dynamic>{
          'insert': line,
          if (inline.isNotEmpty) 'attributes': inline,
        });
      }
      operations.add(<String, dynamic>{
        'insert': '\n',
        if (paragraph.isNotEmpty) 'attributes': paragraph,
      });
    }
    return jsonEncode(operations);
  }

  String? _scaledDeltaJson(
    String? deltaJson, {
    required double scale,
    required double fallbackSize,
  }) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return deltaJson;
    }
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return deltaJson;
      }
      final scaled = decoded.map((raw) {
        if (raw is! Map) {
          return raw;
        }
        final op = Map<String, dynamic>.from(raw);
        final insert = op['insert'];
        if (insert is! String || insert.isEmpty) {
          return op;
        }
        final attributes = op['attributes'] is Map
            ? Map<String, dynamic>.from(op['attributes'] as Map)
            : <String, dynamic>{};
        final currentSize =
            double.tryParse(attributes['size']?.toString() ?? '') ??
            fallbackSize;
        attributes['size'] = (currentSize * scale)
            .clamp(_minTextFontSize, _maxTextFontSize)
            .round()
            .toString();
        op['attributes'] = attributes;
        return op;
      }).toList();
      return jsonEncode(scaled);
    } catch (_) {
      return deltaJson;
    }
  }

  String _colorToHex(Color color) {
    final value = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${value.substring(2)}';
  }
}

class _TextHudStyle {
  const _TextHudStyle({required this.textStyle, required this.textAlign});

  final TextStyle textStyle;
  final TextAlign textAlign;
}
