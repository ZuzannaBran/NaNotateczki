import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fluera_canvas/fluera_canvas.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/note_page.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';

/// Experimental bridge that delegates active text interaction to Fluera.
///
/// Ink, images, PDF blocks and the existing viewport transform stay owned by
/// NaNotateczki. Fluera is mounted only while one text block on this page is
/// active, with its camera pinned to the page's logical coordinate system.
class FlueraTextLayer extends StatefulWidget {
  const FlueraTextLayer({
    required this.controller,
    required this.page,
    required this.pageIndex,
    required this.worldOrigin,
    required this.interactionEnabled,
    super.key,
  });

  final EditorController controller;
  final NotePage page;
  final int pageIndex;
  final Offset worldOrigin;
  final bool interactionEnabled;

  @override
  State<FlueraTextLayer> createState() => _FlueraTextLayerState();
}

class _FlueraTextLayerState extends State<FlueraTextLayer> {
  static const double _minTextWidth = 72;
  static const double _maxTextWidth = 1200;
  static const double _minFontSize = 8;
  static const double _maxFontSize = 96;
  static const Duration _doubleTapWindow = Duration(milliseconds: 360);
  static const double _doubleTapDistance = 24;

  final GlobalKey<FlueraCanvasState> _canvasKey =
      GlobalKey<FlueraCanvasState>();
  late final InfiniteCanvasController _camera = InfiniteCanvasController(
    minScale: 0.999,
    maxScale: 1.001,
    panBoundary: Rect.zero,
  );

  bool _seeding = true;
  bool _pointerActive = false;
  bool _pointerMoved = false;
  bool _resettingCamera = false;
  Offset? _pointerDown;
  DateTime? _lastTapAt;
  Offset? _lastTapPosition;
  Timer? _syncTimer;
  Listenable? _layerChanges;

  @override
  void initState() {
    super.initState();
    _camera.addListener(_keepCameraIdentity);
    WidgetsBinding.instance.addPostFrameCallback((_) => _seedCanvas());
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _layerChanges?.removeListener(_onFlueraChanged);
    _camera.removeListener(_keepCameraIdentity);
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: IgnorePointer(
        ignoring: !widget.interactionEnabled,
        child: FlueraCanvas(
          key: _canvasKey,
          controller: _camera,
          background: const CanvasBackground.solid(Color(0x00000000)),
          tool: CanvasTool.select,
          historyCapacity: 64,
          enableKeyboardShortcuts: false,
          enableNativeLiveStroke: false,
          smartGuidesEnabled: true,
          semanticsEnabled: false,
        ),
      ),
    );
  }

  void _seedCanvas() {
    if (!mounted) {
      return;
    }
    final state = _canvasKey.currentState;
    final activeId = widget.controller.activeTextBlockId;
    if (state == null || activeId == null) {
      return;
    }

    final defaultFontFamily =
        Theme.of(context).textTheme.bodyMedium?.fontFamily ?? 'Roboto';
    for (final block in widget.page.textBlocks) {
      state.addTextNode(
        _nodeFromBlock(block, defaultFontFamily: defaultFontFamily),
      );
    }
    state.clearHistory();
    state.select(NodeId(activeId));

    _layerChanges = state.layerChanges;
    _layerChanges!.addListener(_onFlueraChanged);
    _seeding = false;

    if (widget.controller.tool == DrawingTool.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final currentState = _canvasKey.currentState;
        if (currentState != null &&
            currentState.findNode(NodeId(activeId)) is TextNode) {
          FlueraTextEditor.start(currentState, existing: NodeId(activeId));
        }
      });
    }
  }

  TextNode _nodeFromBlock(
    TextBlock block, {
    required String defaultFontFamily,
  }) {
    final attributes = _firstInlineAttributes(block.deltaJson);
    final decorations = <TextDecoration>[
      if (attributes['underline'] == true) TextDecoration.underline,
      if (attributes['strike'] == true) TextDecoration.lineThrough,
    ];
    final fontFamily =
        attributes['font']?.toString().trim().isNotEmpty == true
        ? attributes['font'].toString()
        : defaultFontFamily;

    return TextNode(
      id: NodeId(block.id),
      textElement: DigitalTextElement(
        id: block.id,
        text: block.text,
        position: block.position - widget.worldOrigin,
        color: block.color,
        fontSize: block.fontSize,
        fontWeight: attributes['bold'] == true
            ? FontWeight.bold
            : FontWeight.normal,
        fontStyle: attributes['italic'] == true
            ? FontStyle.italic
            : FontStyle.normal,
        fontFamily: fontFamily,
        textDecoration: decorations.isEmpty
            ? TextDecoration.none
            : TextDecoration.combine(decorations),
        rotation: block.rotation,
        maxWidth: block.width,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
  }

  void _keepCameraIdentity() {
    if (_resettingCamera) {
      return;
    }
    if (_camera.offset == Offset.zero &&
        (_camera.scale - 1).abs() < 0.000001) {
      return;
    }
    _resettingCamera = true;
    _camera.setOffset(Offset.zero);
    _camera.setScale(1);
    _resettingCamera = false;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerActive = true;
    _pointerMoved = false;
    _pointerDown = event.localPosition;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _pointerDown;
    if (start != null && (event.localPosition - start).distance > 5) {
      _pointerMoved = true;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointerActive = false;
    final wasMoved = _pointerMoved;
    _pointerMoved = false;
    _pointerDown = null;

    if (!wasMoved && _isDoubleTap(event.localPosition)) {
      _openEditorAt(event.localPosition);
      return;
    }
    if (!wasMoved) {
      _lastTapAt = DateTime.now();
      _lastTapPosition = event.localPosition;
    } else {
      _lastTapAt = null;
      _lastTapPosition = null;
    }
    _scheduleSync();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerActive = false;
    _pointerMoved = false;
    _pointerDown = null;
    _scheduleSync();
  }

  bool _isDoubleTap(Offset position) {
    final lastAt = _lastTapAt;
    final lastPosition = _lastTapPosition;
    if (lastAt == null || lastPosition == null) {
      return false;
    }
    final isFastEnough = DateTime.now().difference(lastAt) <= _doubleTapWindow;
    final isCloseEnough =
        (position - lastPosition).distance <= _doubleTapDistance;
    if (!isFastEnough || !isCloseEnough) {
      return false;
    }
    _lastTapAt = null;
    _lastTapPosition = null;
    return true;
  }

  void _openEditorAt(Offset localPosition) {
    final state = _canvasKey.currentState;
    if (state == null) {
      return;
    }
    final hit = state.hitTest(_camera.screenToCanvas(localPosition));
    if (hit == null || state.findNode(hit) is! TextNode) {
      _scheduleSync();
      return;
    }

    final currentId = widget.controller.activeTextBlockId;
    widget.controller.setTool(DrawingTool.text);
    widget.controller.setActiveTextBlock(hit.value, null);

    if (currentId == hit.value) {
      FlueraTextEditor.start(state, existing: hit);
    }
  }

  void _onFlueraChanged() {
    if (_seeding || _pointerActive || FlueraTextEditor.isEditing) {
      return;
    }
    _scheduleSync();
  }

  void _scheduleSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 24), _syncFromFluera);
  }

  void _syncFromFluera() {
    if (!mounted || _seeding || _pointerActive) {
      return;
    }
    final state = _canvasKey.currentState;
    if (state == null) {
      return;
    }

    final selectedId = _singleSelectedTextId(state);
    if (selectedId == null) {
      if (!FlueraTextEditor.isEditing &&
          widget.controller.activeTextBlockId != null) {
        widget.controller.clearActiveTextBlock();
      }
      state.clearHistory();
      return;
    }

    final node = state.findNode(NodeId(selectedId));
    final before = widget.controller.findTextBlockById(selectedId);
    if (node is! TextNode || before == null) {
      return;
    }

    final after = _blockFromNode(before, node);
    state.clearHistory();
    widget.controller.syncExternalTextBlockOnPage(widget.pageIndex, after);

    if (widget.controller.activeTextBlockId != selectedId) {
      widget.controller.setActiveTextBlock(selectedId, null);
    }

    if (widget.controller.tool == DrawingTool.text &&
        !FlueraTextEditor.isEditing) {
      widget.controller.setTool(DrawingTool.edit);
      widget.controller.setActiveTextBlock(selectedId, null);
    }
  }

  String? _singleSelectedTextId(FlueraCanvasState state) {
    final ids = state.selection.ids;
    if (ids.length == 1) {
      final id = ids.first;
      if (state.findNode(id) is TextNode) {
        return id.value;
      }
    }

    final activeId = widget.controller.activeTextBlockId;
    if (activeId != null &&
        state.findNode(NodeId(activeId)) is TextNode &&
        FlueraTextEditor.isEditing) {
      return activeId;
    }
    return null;
  }

  TextBlock _blockFromNode(TextBlock before, TextNode node) {
    final element = node.textElement;
    final matrix = node.localTransform;
    final storage = matrix.storage;
    final scaleX = math.sqrt(
      storage[0] * storage[0] + storage[1] * storage[1],
    );
    final scaleY = math.sqrt(
      storage[4] * storage[4] + storage[5] * storage[5],
    );
    final safeScaleX = scaleX.isFinite && scaleX > 0 ? scaleX : 1.0;
    final safeScaleY = scaleY.isFinite && scaleY > 0 ? scaleY : 1.0;
    final matrixRotation = math.atan2(storage[1], storage[0]);

    final localPosition = MatrixUtils.transformPoint(
      matrix,
      element.position,
    );
    final text = element.text.trimRight();
    final fontSize = _round(
      (element.fontSize * safeScaleY).clamp(_minFontSize, _maxFontSize),
    );
    final width = _round(
      ((element.maxWidth ?? before.width) * safeScaleX).clamp(
        _minTextWidth,
        _maxTextWidth,
      ),
    );
    final rotation = _normalizeAngle(element.rotation + matrixRotation);
    final deltaJson = text == before.text
        ? before.deltaJson
        : _uniformDeltaJson(
            previousDeltaJson: before.deltaJson,
            text: text,
            fontSize: fontSize,
            color: element.color,
            fontFamily: element.fontFamily,
            fontWeight: element.fontWeight,
            fontStyle: element.fontStyle,
            decoration: element.textDecoration,
          );

    return before.copyWith(
      text: text,
      deltaJson: deltaJson,
      position: Offset(
        _round(localPosition.dx + widget.worldOrigin.dx),
        _round(localPosition.dy + widget.worldOrigin.dy),
      ),
      fontSize: fontSize,
      color: element.color,
      width: width,
      rotation: _round(rotation),
    );
  }

  Map<String, dynamic> _firstInlineAttributes(String? deltaJson) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return <String, dynamic>{};
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
        final rawAttributes = op['attributes'];
        return rawAttributes is Map
            ? Map<String, dynamic>.from(rawAttributes)
            : <String, dynamic>{};
      }
    } catch (_) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  String _uniformDeltaJson({
    required String? previousDeltaJson,
    required String text,
    required double fontSize,
    required Color color,
    required String fontFamily,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
    required TextDecoration decoration,
  }) {
    final inline = _firstInlineAttributes(previousDeltaJson);
    inline['size'] = fontSize.round().toString();
    inline['color'] = _colorToHex(color);
    if (fontFamily.trim().isEmpty) {
      inline.remove('font');
    } else {
      inline['font'] = fontFamily;
    }
    _setBooleanAttribute(
      inline,
      'bold',
      fontWeight.value >= FontWeight.w600.value,
    );
    _setBooleanAttribute(inline, 'italic', fontStyle == FontStyle.italic);
    _setBooleanAttribute(
      inline,
      'underline',
      decoration.contains(TextDecoration.underline),
    );
    _setBooleanAttribute(
      inline,
      'strike',
      decoration.contains(TextDecoration.lineThrough),
    );

    final paragraphAttributes = _paragraphAttributes(previousDeltaJson);
    final lines = text.split('\n');
    final operations = <Map<String, dynamic>>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isNotEmpty) {
        operations.add(<String, dynamic>{
          'insert': line,
          if (inline.isNotEmpty)
            'attributes': Map<String, dynamic>.from(inline),
        });
      }
      final paragraph = i < paragraphAttributes.length
          ? paragraphAttributes[i]
          : const <String, dynamic>{};
      operations.add(<String, dynamic>{
        'insert': '\n',
        if (paragraph.isNotEmpty)
          'attributes': Map<String, dynamic>.from(paragraph),
      });
    }
    return jsonEncode(operations);
  }

  List<Map<String, dynamic>> _paragraphAttributes(String? deltaJson) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    const paragraphKeys = <String>{
      'align',
      'blockquote',
      'code-block',
      'direction',
      'header',
      'indent',
      'list',
    };
    final result = <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return result;
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
        final rawAttributes = op['attributes'];
        final attributes = rawAttributes is Map
            ? Map<String, dynamic>.from(rawAttributes)
            : <String, dynamic>{};
        final paragraph = <String, dynamic>{
          for (final entry in attributes.entries)
            if (paragraphKeys.contains(entry.key)) entry.key: entry.value,
        };
        final newlineCount = '\n'.allMatches(insert).length;
        for (var i = 0; i < newlineCount; i++) {
          result.add(Map<String, dynamic>.from(paragraph));
        }
      }
    } catch (_) {
      return result;
    }
    return result;
  }

  void _setBooleanAttribute(
    Map<String, dynamic> attributes,
    String key,
    bool enabled,
  ) {
    if (enabled) {
      attributes[key] = true;
    } else {
      attributes.remove(key);
    }
  }

  String _colorToHex(Color color) {
    final value = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#' + value.substring(2);
  }

  double _normalizeAngle(double angle) {
    var normalized = angle;
    while (normalized > math.pi) {
      normalized -= math.pi * 2;
    }
    while (normalized < -math.pi) {
      normalized += math.pi * 2;
    }
    return normalized;
  }

  double _round(double value) => (value * 1000).roundToDouble() / 1000;
}
