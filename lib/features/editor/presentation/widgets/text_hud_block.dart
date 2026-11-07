import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../../../core/input/soft_keyboard.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';
import '../../state/quill_paste_plan.dart';
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
  static const double _maxTextFontSize = 192;

  final GlobalKey _contentKey = GlobalKey();
  final GlobalKey<EditableTextState> _editableKey =
      GlobalKey<EditableTextState>();
  late final TextEditingController _textController;
  final FocusNode _focusNode = FocusNode();

  double _frameHeight = _frameMinHeight;
  bool _metricsScheduled = false;
  bool _focusRequestScheduled = false;
  TextBlock? _transformBefore;
  TextBlock? _transformPreview;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.block.text);
    _bindController();
  }

  @override
  void didUpdateWidget(covariant TextHudBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.block.id != widget.block.id) {
      oldWidget.controller.unbindHudTextController(
        oldWidget.block.id,
        _textController,
      );
    }
    _bindController();
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
    widget.controller.unbindHudTextController(widget.block.id, _textController);
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _bindController() {
    if (widget.interactionEnabled) {
      widget.controller.bindHudTextController(widget.block.id, _textController);
    } else {
      widget.controller.unbindHudTextController(
        widget.block.id,
        _textController,
      );
    }
  }

  Future<void> _pasteRichClipboard([
    SelectionChangedCause cause = SelectionChangedCause.keyboard,
  ]) async {
    final editor = widget.controller;
    final originalValue = _textController.value;
    bool current() =>
        mounted &&
        identical(editor.activeHudTextController, _textController) &&
        _textController.value == originalValue;
    if (!current()) {
      return;
    }
    try {
      final clipboard = SystemClipboard.instance;
      Future<ClipboardReader>? snapshot;
      Future<ClipboardReader> reader() => snapshot ??= clipboard!.read();
      final handled =
          clipboard != null &&
          await editor.pasteQuillHtml(
            blockId: widget.block.id,
            canPaste: current,
            readHtml: () async {
              final value = await reader();
              return value.canProvide(Formats.htmlText)
                  ? await value.readValue(Formats.htmlText)
                  : null;
            },
            readPlainText: () async {
              final value = await reader();
              return value.canProvide(Formats.plainText)
                  ? await value.readValue(Formats.plainText)
                  : null;
            },
          );
      if (!handled && current()) {
        if (clipboard != null) {
          final value = await reader();
          final format = value.canProvide(Formats.png)
              ? Formats.png
              : value.canProvide(Formats.jpeg)
              ? Formats.jpeg
              : null;
          if (format != null && current()) {
            await editor.insertQuillFile(
              blockId: widget.block.id,
              canInsert: current,
              readBytes: () => _readClipboardImage(value, format),
            );
            return;
          }
        }
        if (!current()) {
          return;
        }
        await _editableKey.currentState?.pasteText(cause);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Could not paste this rich content.')),
        );
      }
    }
  }

  Future<Uint8List?> _readClipboardImage(
    ClipboardReader reader,
    SimpleFileFormat format,
  ) {
    final result = Completer<Uint8List?>();
    reader.getFile(
      format,
      (file) async {
        try {
          result.complete(
            await QuillPastePlan.readMediaBytes(file.getStream()),
          );
        } catch (error, stack) {
          if (!result.isCompleted) {
            result.completeError(error, stack);
          }
        }
      },
      onError: (error) {
        if (!result.isCompleted) {
          result.completeError(error);
        }
      },
      synthesizeFilesFromURIs: false,
    );
    return result.future.timeout(const Duration(seconds: 20));
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
          _buildContent(isEditing, _transformPreview ?? widget.block),
          ObjectTransformHud<TextBlock>(
            key: ValueKey('object-hud-text-${widget.block.id}'),
            data: widget.block,
            rect: rect,
            rotation: widget.block.rotation,
            interactive: widget.interactionEnabled,
            showHandles: true,
            draggable: !isEditing,
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
            onTransformStart: _beginTransform,
            onTransformEnd: widget.controller.endObjectTransform,
            onPreview: _previewTransform,
            onCommit: _commitTransform,
            onCancel: _cancelTransform,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool isEditing, TextBlock block) {
    final style = _styleFor(block, block.fontSize);
    final localPosition = block.position - widget.worldOrigin;
    return Positioned(
      left: localPosition.dx,
      top: localPosition.dy,
      width: block.width,
      child: Transform.rotate(
        angle: block.rotation,
        alignment: Alignment.center,
        child: Container(
          key: _contentKey,
          width: block.width,
          constraints: const BoxConstraints(minHeight: _frameMinHeight),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.transparent, width: 1.2),
          ),
          child: IgnorePointer(
            ignoring: !isEditing,
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                if (isEditing && widget.controller.operationWriter != null) ...{
                  const SingleActivator(
                    LogicalKeyboardKey.keyV,
                    control: true,
                  ): () =>
                      _pasteRichClipboard(),
                  const SingleActivator(
                    LogicalKeyboardKey.keyV,
                    meta: true,
                  ): () =>
                      _pasteRichClipboard(),
                },
                if (isEditing && _textController.text.isEmpty)
                  const SingleActivator(LogicalKeyboardKey.delete): () {
                    widget.controller.deleteTextBlockOnPage(
                      widget.pageIndex,
                      widget.block.id,
                    );
                  },
              },
              child: EditableText(
                key: _editableKey,
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
                contextMenuBuilder: widget.controller.operationWriter == null
                    ? null
                    : (context, state) =>
                          AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: state.contextMenuAnchors,
                            buttonItems: state.contextMenuButtonItems
                                .map(
                                  (item) =>
                                      item.type == ContextMenuButtonType.paste
                                      ? ContextMenuButtonItem(
                                          type: ContextMenuButtonType.paste,
                                          onPressed: () {
                                            state.hideToolbar();
                                            _pasteRichClipboard(
                                              SelectionChangedCause.toolbar,
                                            );
                                          },
                                        )
                                      : item,
                                )
                                .toList(),
                          ),
              ),
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
    if (widget.block.text.isEmpty != value.isEmpty) {
      setState(() {});
    }
    _scheduleMetrics();
  }

  void _beginTransform() {
    if (_transformBefore != null) {
      return;
    }
    widget.controller.beginObjectTransform();
    _transformBefore =
        widget.controller.findTextBlockById(widget.block.id) ?? widget.block;
    widget.controller.commitActiveTextEdit();
  }

  void _previewTransform(TextBlock before, ObjectTransformSnapshot preview) {
    setState(
      () =>
          _transformPreview = _transformed(_transformBefore ?? before, preview),
    );
  }

  TextBlock _transformed(
    TextBlock transformBefore,
    ObjectTransformSnapshot preview,
  ) {
    final scale =
        preview.kind == ObjectTransformKind.resize &&
            preview.handle?.isDiagonal == true &&
            transformBefore.width > 0
        ? preview.rect.width / transformBefore.width
        : 1.0;
    final nextFontSize = (transformBefore.fontSize * scale)
        .clamp(_minTextFontSize, _maxTextFontSize)
        .toDouble();
    final double actualScale = transformBefore.fontSize == 0
        ? 1.0
        : nextFontSize / transformBefore.fontSize;
    final nextDelta = (actualScale - 1).abs() <= 1e-6
        ? transformBefore.deltaJson
        : _scaledDeltaJson(
            transformBefore.deltaJson,
            scale: actualScale,
            fallbackSize: transformBefore.fontSize,
          );

    return transformBefore.copyWith(
      position: preview.rect.topLeft + widget.worldOrigin,
      width: preview.rect.width,
      fontSize: nextFontSize,
      rotation: preview.rotation,
      deltaJson: nextDelta,
    );
  }

  void _commitTransform(TextBlock before, ObjectTransformSnapshot preview) {
    final current = widget.controller.findTextBlockById(before.id);
    _cancelTransform(before);
    if (current == null || widget.controller.activeTextBlockId != before.id) {
      return;
    }
    widget.controller.commitTextUpdateOnPage(
      widget.pageIndex,
      current,
      _transformed(current, preview),
    );
  }

  void _cancelTransform(TextBlock before) {
    _transformBefore = null;
    setState(() => _transformPreview = null);
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

  TextBlockAppearance _styleFor(TextBlock block, double fontSize) {
    return textBlockAppearance(context, block, fontSize: fontSize);
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

TextBlockAppearance textBlockAppearance(
  BuildContext context,
  TextBlock block, {
  double? fontSize,
}) {
  Map<String, dynamic> firstAttributes({required bool paragraph}) {
    final source = block.deltaJson;
    if (source == null || source.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(source);
      if (decoded is! List) {
        return const <String, dynamic>{};
      }
      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }
        final op = Map<String, dynamic>.from(raw);
        final insert = op['insert'];
        if (insert is! String ||
            (paragraph
                ? !insert.contains('\n')
                : insert.replaceAll('\n', '').isEmpty)) {
          continue;
        }
        final attrs = op['attributes'];
        return attrs is Map
            ? Map<String, dynamic>.from(attrs)
            : const <String, dynamic>{};
      }
    } catch (_) {
      return const <String, dynamic>{};
    }
    return const <String, dynamic>{};
  }

  final inline = firstAttributes(paragraph: false);
  final paragraph = firstAttributes(paragraph: true);
  final colorValue = inline['color'];
  Color? inlineColor;
  if (colorValue is String && colorValue.startsWith('#')) {
    final hex = colorValue.substring(1);
    if (hex.length == 6 || hex.length == 8) {
      final value = int.tryParse(hex.length == 6 ? 'ff$hex' : hex, radix: 16);
      if (value != null) {
        inlineColor = Color(value);
      }
    }
  }
  final customFontFamily = inline['font']?.toString();
  final decorations = <TextDecoration>[
    if (inline['underline'] == true) TextDecoration.underline,
    if (inline['strike'] == true) TextDecoration.lineThrough,
  ];
  return TextBlockAppearance(
    textStyle: TextStyle(
      color: AppColors.displayInkColor(
        inlineColor ?? block.color,
        darkMode: Theme.of(context).brightness == Brightness.dark,
      ),
      fontSize: fontSize ?? block.fontSize,
      fontFamily: customFontFamily ?? AppTypography.fontFamily,
      fontFamilyFallback: customFontFamily == null
          ? AppTypography.fontFamilyFallback
          : null,
      fontWeight: inline['bold'] == true ? FontWeight.bold : FontWeight.normal,
      fontStyle: inline['italic'] == true ? FontStyle.italic : FontStyle.normal,
      decoration: decorations.isEmpty
          ? TextDecoration.none
          : TextDecoration.combine(decorations),
      height: 1.25,
    ),
    textAlign: switch (paragraph['align']?.toString()) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => TextAlign.left,
    },
  );
}

class TextBlockAppearance {
  const TextBlockAppearance({required this.textStyle, required this.textAlign});

  final TextStyle textStyle;
  final TextAlign textAlign;
}
