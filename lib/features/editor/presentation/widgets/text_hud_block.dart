import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/input/soft_keyboard.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';
import '../interaction/text_hud_engine.dart';

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
  static const double _handleVisualPx = 10;
  static const double _handleHitPx = 34;
  static const double _sideHandleWidthPx = 7;
  static const double _sideHandleHeightPx = 26;
  static const double _rotationStemPx = 28;

  final GlobalKey _surfaceKey = GlobalKey();
  final GlobalKey _contentKey = GlobalKey();
  final TextHudEngine _engine = TextHudEngine();
  late final TextEditingController _textController;
  final FocusNode _focusNode = FocusNode();

  TextBlock? _gestureBefore;
  TextHudGeometry? _preview;
  double _frameHeight = _frameMinHeight;
  double _screenScale = 1;
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
    if (oldWidget.block.id != widget.block.id) {
      _textController.value = TextEditingValue(
        text: widget.block.text,
        selection: TextSelection.collapsed(
          offset: widget.block.text.length,
        ),
      );
      _preview = null;
      _engine.cancel();
      _gestureBefore = null;
      return;
    }
    if (!_focusNode.hasFocus &&
        !_engine.isActive &&
        _textController.text != widget.block.text) {
      _textController.value = TextEditingValue(
        text: widget.block.text,
        selection: TextSelection.collapsed(
          offset: widget.block.text.length,
        ),
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
    final geometry = _geometryFor(widget.block);
    final style = _styleFor(widget.block, geometry.fontSize);
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

    final accent = Theme.of(context).colorScheme.primary;
    final handleFill = Theme.of(context).colorScheme.surface;

    return Positioned.fill(
      child: SizedBox.expand(
        key: _surfaceKey,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _buildContent(
              geometry: geometry,
              style: style,
              isEditing: isEditing,
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TextHudFramePainter(
                    geometry: geometry,
                    color: accent,
                    strokeWidth: 1.25 / _screenScale,
                    rotationStem: _rotationStemPx / _screenScale,
                    showHandles: !isEditing,
                  ),
                ),
              ),
            ),
            if (!isEditing && widget.interactionEnabled) ...[
              _buildCornerHandle(
                geometry.pointAt(0, 0),
                TextHudOperation.scaleNorthWest,
                accent,
                handleFill,
              ),
              _buildCornerHandle(
                geometry.pointAt(1, 0),
                TextHudOperation.scaleNorthEast,
                accent,
                handleFill,
              ),
              _buildCornerHandle(
                geometry.pointAt(1, 1),
                TextHudOperation.scaleSouthEast,
                accent,
                handleFill,
              ),
              _buildCornerHandle(
                geometry.pointAt(0, 1),
                TextHudOperation.scaleSouthWest,
                accent,
                handleFill,
              ),
              _buildWidthHandle(
                geometry.pointAt(1, 0.5),
                accent,
                handleFill,
              ),
              _buildRotationHandle(
                geometry,
                accent,
                handleFill,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildContent({
    required TextHudGeometry geometry,
    required _TextHudStyle style,
    required bool isEditing,
  }) {
    final body = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: !isEditing
          ? (_) {
              widget.controller.markTextTap();
            }
          : null,
      onDoubleTap: !isEditing ? _enterEditing : null,
      onPanStart: !isEditing && widget.interactionEnabled
          ? (details) {
              _beginGesture(
                TextHudOperation.translate,
                details.globalPosition,
              );
            }
          : null,
      onPanUpdate: !isEditing && widget.interactionEnabled
          ? (details) => _updateGesture(details.globalPosition)
          : null,
      onPanEnd: !isEditing && widget.interactionEnabled
          ? (_) => _endGesture()
          : null,
      onPanCancel: !isEditing && widget.interactionEnabled
          ? _cancelGesture
          : null,
      child: Container(
        key: _contentKey,
        width: geometry.width,
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
    );

    return Positioned(
      left: geometry.position.dx,
      top: geometry.position.dy,
      width: geometry.width,
      child: Transform.rotate(
        angle: geometry.rotation,
        alignment: Alignment.center,
        child: body,
      ),
    );
  }

  Widget _buildCornerHandle(
    Offset point,
    TextHudOperation operation,
    Color border,
    Color fill,
  ) {
    return _buildHandle(
      point: point,
      operation: operation,
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      visualWidth: _handleVisualPx / _screenScale,
      visualHeight: _handleVisualPx / _screenScale,
      border: border,
      fill: fill,
      circular: true,
    );
  }

  Widget _buildWidthHandle(
    Offset point,
    Color border,
    Color fill,
  ) {
    return _buildHandle(
      point: point,
      operation: TextHudOperation.resizeWidth,
      cursor: SystemMouseCursors.resizeLeftRight,
      visualWidth: _sideHandleWidthPx / _screenScale,
      visualHeight: _sideHandleHeightPx / _screenScale,
      border: border,
      fill: fill,
      circular: false,
    );
  }

  Widget _buildRotationHandle(
    TextHudGeometry geometry,
    Color border,
    Color fill,
  ) {
    final topMiddle = geometry.pointAt(0.5, 0);
    final outward = -geometry.axisY;
    final point =
        topMiddle + outward * (_rotationStemPx / _screenScale);
    return _buildHandle(
      point: point,
      operation: TextHudOperation.rotate,
      cursor: SystemMouseCursors.grab,
      visualWidth: _handleVisualPx / _screenScale,
      visualHeight: _handleVisualPx / _screenScale,
      border: border,
      fill: fill,
      circular: true,
    );
  }

  Widget _buildHandle({
    required Offset point,
    required TextHudOperation operation,
    required MouseCursor cursor,
    required double visualWidth,
    required double visualHeight,
    required Color border,
    required Color fill,
    required bool circular,
  }) {
    final hitSize = _handleHitPx / _screenScale;
    return Positioned(
      left: point.dx - hitSize / 2,
      top: point.dy - hitSize / 2,
      width: hitSize,
      height: hitSize,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            _beginGesture(operation, details.globalPosition);
          },
          onPanUpdate: (details) {
            _updateGesture(details.globalPosition);
          },
          onPanEnd: (_) {
            _endGesture();
          },
          onPanCancel: _cancelGesture,
          child: Center(
            child: Container(
              width: visualWidth,
              height: visualHeight,
              decoration: BoxDecoration(
                color: fill,
                border: Border.all(
                  color: border,
                  width: 1.25 / _screenScale,
                ),
                borderRadius: circular
                    ? BorderRadius.circular(999)
                    : BorderRadius.circular(2 / _screenScale),
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
    _scheduleMetrics();
  }

  void _beginGesture(
    TextHudOperation operation,
    Offset globalPosition,
  ) {
    final current = widget.controller.findTextBlockById(widget.block.id);
    if (current == null) {
      return;
    }
    final geometry = _geometryFor(current);
    _gestureBefore = current;
    _engine.begin(
      operation,
      geometry,
      _globalToLocal(globalPosition),
    );
    setState(() {
      _preview = geometry;
    });
  }

  void _updateGesture(Offset globalPosition) {
    if (!_engine.isActive) {
      return;
    }
    final preview = _engine.update(
      _globalToLocal(globalPosition),
      shift: HardwareKeyboard.instance.isShiftPressed,
    );
    setState(() {
      _preview = preview;
    });
    _scheduleMetrics();
  }

  void _endGesture() {
    final before = _gestureBefore;
    final result = _engine.end();
    _gestureBefore = null;
    if (before == null || result == null) {
      if (mounted) {
        setState(() {
          _preview = null;
        });
      }
      return;
    }

    final scale = before.fontSize == 0
        ? 1.0
        : result.fontSize / before.fontSize;
    final after = before.copyWith(
      position: result.position + widget.worldOrigin,
      width: result.width,
      fontSize: result.fontSize,
      rotation: result.rotation,
      deltaJson: (scale - 1).abs() <= 1e-6
          ? before.deltaJson
          : _scaledDeltaJson(
              before.deltaJson,
              scale: scale,
              fallbackSize: before.fontSize,
            ),
    );

    setState(() {
      _preview = null;
    });
    widget.controller.commitTextUpdateOnPage(
      widget.pageIndex,
      before,
      after,
    );
  }

  void _cancelGesture() {
    _engine.cancel();
    _gestureBefore = null;
    if (mounted) {
      setState(() {
        _preview = null;
      });
    }
  }

  TextHudGeometry _geometryFor(TextBlock block) {
    final preview = _preview;
    if (preview != null) {
      return preview;
    }
    return TextHudGeometry(
      position: block.position - widget.worldOrigin,
      width: block.width,
      height: _frameHeight,
      fontSize: block.fontSize,
      rotation: block.rotation,
    );
  }

  Offset _globalToLocal(Offset point) {
    final renderObject =
        _surfaceKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox) {
      return renderObject.globalToLocal(point);
    }
    return point;
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

      final contentObject =
          _contentKey.currentContext?.findRenderObject();
      final surfaceObject =
          _surfaceKey.currentContext?.findRenderObject();
      if (contentObject is! RenderBox || surfaceObject is! RenderBox) {
        return;
      }

      final measuredHeight = math.max(
        _frameMinHeight,
        contentObject.size.height,
      );
      final origin = surfaceObject.localToGlobal(Offset.zero);
      final oneUnit = surfaceObject.localToGlobal(const Offset(1, 0));
      final measuredScale = math.max(
        0.01,
        (oneUnit - origin).distance,
      );

      final heightChanged =
          (measuredHeight - _frameHeight).abs() > 0.5;
      final scaleChanged =
          (measuredScale - _screenScale).abs() > 0.01;
      if (!heightChanged && !scaleChanged) {
        return;
      }

      setState(() {
        _frameHeight = measuredHeight;
        _screenScale = measuredScale;
        final preview = _preview;
        if (preview != null &&
            _engine.operation == TextHudOperation.resizeWidth) {
          _preview = preview.copyWith(height: measuredHeight);
        }
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
        fontWeight:
            inline['bold'] == true ? FontWeight.bold : FontWeight.normal,
        fontStyle:
            inline['italic'] == true ? FontStyle.italic : FontStyle.normal,
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
            .clamp(8.0, 96.0)
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
  const _TextHudStyle({
    required this.textStyle,
    required this.textAlign,
  });

  final TextStyle textStyle;
  final TextAlign textAlign;
}

class _TextHudFramePainter extends CustomPainter {
  const _TextHudFramePainter({
    required this.geometry,
    required this.color,
    required this.strokeWidth,
    required this.rotationStem,
    required this.showHandles,
  });

  final TextHudGeometry geometry;
  final Color color;
  final double strokeWidth;
  final double rotationStem;
  final bool showHandles;

  @override
  void paint(Canvas canvas, Size size) {
    final northWest = geometry.pointAt(0, 0);
    final northEast = geometry.pointAt(1, 0);
    final southEast = geometry.pointAt(1, 1);
    final southWest = geometry.pointAt(0, 1);
    final path = Path()
      ..moveTo(northWest.dx, northWest.dy)
      ..lineTo(northEast.dx, northEast.dy)
      ..lineTo(southEast.dx, southEast.dy)
      ..lineTo(southWest.dx, southWest.dy)
      ..close();

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, paint);

    if (!showHandles) {
      return;
    }
    final topMiddle = geometry.pointAt(0.5, 0);
    final rotationPoint =
        topMiddle - geometry.axisY * rotationStem;
    canvas.drawLine(topMiddle, rotationPoint, paint);
  }

  @override
  bool shouldRepaint(covariant _TextHudFramePainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.rotationStem != rotationStem ||
        oldDelegate.showHandles != showHandles;
  }
}
