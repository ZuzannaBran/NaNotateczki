import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_plus/webview_plus.dart';

import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/note_page.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';

/// Experimental DOM-backed text scene.
///
/// While a text block is active, all text blocks on this page are rendered in
/// one transparent WebView. Browser-native contenteditable handles typing and
/// Moveable handles selection, drag, width resize, scale and rotation. Ink and
/// media stay in the existing Flutter layers.
class WebTextEditorLayer extends StatefulWidget {
  const WebTextEditorLayer({
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
  State<WebTextEditorLayer> createState() => _WebTextEditorLayerState();
}

class _WebTextEditorLayerState extends State<WebTextEditorLayer> {
  static const double _minWidth = 72;
  static const double _maxWidth = 1200;
  static const double _minFontSize = 8;
  static const double _maxFontSize = 96;

  WebviewPlusController? _webController;
  late final String _initialHtml = _buildHtml();
  bool _ready = false;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !widget.interactionEnabled,
      child: Stack(
        children: [
          if (!_ready)
            Positioned.fill(
              child: IgnorePointer(
                child: Stack(
                  children: [
                    for (final block in widget.page.textBlocks)
                      _fallbackText(block),
                  ],
                ),
              ),
            ),
          Positioned.fill(
            child: WebviewWidget(
              initialData: WebviewInitialData(_initialHtml),
              initialSettings: WebviewSettings(
                javaScriptEnabled: true,
                transparentBackground: true,
                initialBackgroundColor: Colors.transparent,
                supportZoom: false,
                builtInZoomControls: false,
                displayZoomControls: false,
                hideNativeScrollbars: true,
                disableLinkHoverPreview: true,
                disablePrinting: true,
                isInspectable: kDebugMode,
                selectionTextColor: const Color(0x553A78FF),
              ),
              onWebViewCreated: _onWebViewCreated,
              onMessageReceived: (_, message) {
                _handleFallbackMessage(message);
              },
              onReceivedError: (_, url, code, description) {
                debugPrint(
                  'WebTextEditorLayer: webview error '
                  '$code for $url: $description',
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackText(TextBlock block) {
    final style = _styleFromBlock(block);
    final local = block.position - widget.worldOrigin;
    Widget child = SizedBox(
      width: block.width,
      child: Text(
        block.text,
        style: TextStyle(
          color: block.color,
          fontSize: block.fontSize,
          fontFamily: style.fontFamily,
          fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
          decoration: TextDecoration.combine([
            if (style.underline) TextDecoration.underline,
            if (style.strike) TextDecoration.lineThrough,
          ]),
          height: 1.25,
        ),
        textAlign: style.textAlign,
      ),
    );
    if (block.rotation != 0) {
      child = Transform.rotate(
        angle: block.rotation,
        alignment: Alignment.topLeft,
        child: child,
      );
    }
    return Positioned(
      left: local.dx,
      top: local.dy,
      child: child,
    );
  }

  void _onWebViewCreated(WebviewPlusController controller) {
    _webController = controller;
    controller.addJavaScriptHandler(
      handlerName: 'editorEvent',
      callback: _handleEditorEvent,
    );
  }

  Future<Map<String, dynamic>> _handleEditorEvent(List<dynamic> args) async {
    if (args.isEmpty || args.first is! Map) {
      return const <String, dynamic>{'ok': false};
    }
    final event = Map<String, dynamic>.from(args.first as Map);
    final type = event['type']?.toString();

    switch (type) {
      case 'ready':
        if (mounted && !_ready) {
          setState(() {
            _ready = true;
          });
        }
        return const <String, dynamic>{'ok': true};
      case 'select':
        final id = event['id']?.toString();
        if (id != null && widget.controller.findTextBlockById(id) != null) {
          widget.controller.markTextTap();
          widget.controller.setActiveTextBlock(id, null);
        }
        return const <String, dynamic>{'ok': true};
      case 'editStart':
        final id = event['id']?.toString();
        if (id != null && widget.controller.findTextBlockById(id) != null) {
          widget.controller.markTextTap();
          if (widget.controller.tool != DrawingTool.text) {
            widget.controller.setTool(DrawingTool.text);
          }
          widget.controller.setActiveTextBlock(id, null);
        }
        return const <String, dynamic>{'ok': true};
      case 'commit':
        _commitEvent(event);
        return const <String, dynamic>{'ok': true};
      case 'delete':
        final id = event['id']?.toString();
        if (id != null && widget.controller.findTextBlockById(id) != null) {
          widget.controller.deleteTextBlockOnPage(widget.pageIndex, id);
        }
        return const <String, dynamic>{'ok': true};
      case 'deselect':
        if (widget.controller.tool == DrawingTool.text) {
          widget.controller.setTool(DrawingTool.edit);
        } else {
          widget.controller.clearActiveTextBlock();
        }
        return const <String, dynamic>{'ok': true};
      case 'engineError':
        debugPrint(
          'WebTextEditorLayer: Moveable failed to load: '
          + (event['message']?.toString() ?? 'unknown error'),
        );
        return const <String, dynamic>{'ok': true};
    }
    return const <String, dynamic>{'ok': false};
  }

  void _handleFallbackMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map) {
        _handleEditorEvent(<dynamic>[decoded]);
      }
    } catch (_) {
      return;
    }
  }

  void _commitEvent(Map<String, dynamic> event) {
    final id = event['id']?.toString();
    if (id == null) {
      return;
    }
    final before = widget.controller.findTextBlockById(id);
    if (before == null) {
      return;
    }

    final x = _finiteDouble(event['x'], before.position.dx - widget.worldOrigin.dx);
    final y = _finiteDouble(event['y'], before.position.dy - widget.worldOrigin.dy);
    final width = _finiteDouble(event['width'], before.width)
        .clamp(_minWidth, _maxWidth)
        .toDouble();
    final fontSize = _finiteDouble(event['fontSize'], before.fontSize)
        .clamp(_minFontSize, _maxFontSize)
        .toDouble();
    final rotationDegrees = _finiteDouble(
      event['rotation'],
      before.rotation * 180 / math.pi,
    );
    final text = (event['text']?.toString() ?? before.text).trimRight();

    final after = before.copyWith(
      text: text,
      deltaJson: text == before.text
          ? before.deltaJson
          : _uniformDeltaJson(
              before.deltaJson,
              text: text,
              fontSize: fontSize,
              color: before.color,
            ),
      position: Offset(
        x + widget.worldOrigin.dx,
        y + widget.worldOrigin.dy,
      ),
      width: width,
      fontSize: fontSize,
      rotation: rotationDegrees * math.pi / 180,
    );
    widget.controller.commitExternalTextBlockOnPage(
      widget.pageIndex,
      after,
    );
  }

  double _finiteDouble(dynamic value, double fallback) {
    final parsed = switch (value) {
      num number => number.toDouble(),
      String string => double.tryParse(string),
      _ => null,
    };
    if (parsed == null || !parsed.isFinite) {
      return fallback;
    }
    return parsed;
  }

  String _buildHtml() {
    final blocks = widget.page.textBlocks.map(_blockPayload).toList();
    final payload = <String, dynamic>{
      'activeId': widget.controller.activeTextBlockId,
      'autoEdit': widget.controller.tool == DrawingTool.text,
      'blocks': blocks,
    };
    final encoded = base64Encode(utf8.encode(jsonEncode(payload)));
    return _htmlTemplate.replaceFirst('__PAYLOAD__', encoded);
  }

  Map<String, dynamic> _blockPayload(TextBlock block) {
    final style = _styleFromBlock(block);
    final local = block.position - widget.worldOrigin;
    return <String, dynamic>{
      'id': block.id,
      'text': block.text,
      'x': local.dx,
      'y': local.dy,
      'width': block.width,
      'fontSize': block.fontSize,
      'color': _cssColor(block.color),
      'rotation': block.rotation * 180 / math.pi,
      'fontFamily': style.fontFamily,
      'bold': style.bold,
      'italic': style.italic,
      'underline': style.underline,
      'strike': style.strike,
      'align': style.align,
    };
  }

  _WebTextStyle _styleFromBlock(TextBlock block) {
    final inline = _firstInlineAttributes(block.deltaJson);
    final paragraph = _firstParagraphAttributes(block.deltaJson);
    final align = paragraph['align']?.toString();
    return _WebTextStyle(
      fontFamily: inline['font']?.toString(),
      bold: inline['bold'] == true,
      italic: inline['italic'] == true,
      underline: inline['underline'] == true,
      strike: inline['strike'] == true,
      align: switch (align) {
        'center' => 'center',
        'right' => 'right',
        'justify' => 'justify',
        _ => 'left',
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

  String _uniformDeltaJson(
    String? previousDeltaJson, {
    required String text,
    required double fontSize,
    required Color color,
  }) {
    final inline = Map<String, dynamic>.from(
      _firstInlineAttributes(previousDeltaJson),
    );
    inline['size'] = fontSize.round().toString();
    inline['color'] = _quillColor(color);

    final paragraph = Map<String, dynamic>.from(
      _firstParagraphAttributes(previousDeltaJson),
    );
    final operations = <Map<String, dynamic>>[];
    final lines = text.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
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

  String _quillColor(Color color) {
    final value = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#' + value.substring(2);
  }

  String _cssColor(Color color) {
    return 'rgba('
        + color.r.toInt().toString()
        + ','
        + color.g.toInt().toString()
        + ','
        + color.b.toInt().toString()
        + ','
        + (color.a / 255).toStringAsFixed(4)
        + ')';
  }

  TextAlign get _unusedTextAlign => TextAlign.left;

  static const String _htmlTemplate = r'''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<script src="https://cdn.jsdelivr.net/npm/moveable@0.53.0/dist/moveable.min.js"></script>
<style>
  html, body {
    margin: 0;
    padding: 0;
    width: 100%;
    height: 100%;
    overflow: hidden;
    background: transparent !important;
  }
  * {
    box-sizing: border-box;
  }
  #stage {
    position: relative;
    width: 100%;
    height: 100%;
    overflow: hidden;
    background: transparent;
    touch-action: none;
    font-synthesis: none;
  }
  .text-object {
    position: absolute;
    min-height: 20px;
    margin: 0;
    padding: 2px 3px;
    border: 0;
    outline: 0;
    background: transparent;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    line-height: 1.25;
    transform-origin: 0 0;
    user-select: none;
    cursor: default;
  }
  .text-object.editing {
    outline: 1px solid rgba(90, 90, 90, 0.55);
    user-select: text;
    cursor: text;
  }
  .moveable-line {
    background: #767676 !important;
  }
  .moveable-control {
    width: 9px !important;
    height: 9px !important;
    margin-top: -4.5px !important;
    margin-left: -4.5px !important;
    border: 1.25px solid #767676 !important;
    background: #ffffff !important;
    box-shadow: 0 0 0 1px rgba(255,255,255,.72);
  }
  .moveable-rotation-line {
    background: #767676 !important;
    width: 1px !important;
  }
  .moveable-rotation-control {
    border-radius: 50% !important;
  }
</style>
</head>
<body>
<div id="stage"></div>
<script>
(function () {
  "use strict";

  const encoded = "__PAYLOAD__";
  const bytes = Uint8Array.from(atob(encoded), function (char) {
    return char.charCodeAt(0);
  });
  const initial = JSON.parse(new TextDecoder().decode(bytes));
  const stage = document.getElementById("stage");
  let moveable = null;
  let selected = null;
  let editing = null;
  let finishingEdit = false;
  let resizeStart = null;
  let dragStart = null;

  function bridgeCall(payload) {
    if (window.webview_plus && window.webview_plus.callHandler) {
      return window.webview_plus.callHandler("editorEvent", payload);
    }
    if (window.WebviewPlusChannel && window.WebviewPlusChannel.postMessage) {
      window.WebviewPlusChannel.postMessage(JSON.stringify(payload));
    }
    return Promise.resolve({ok: false});
  }

  function number(value, fallback) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  function snapshot(target) {
    return {
      type: "commit",
      id: target.dataset.id,
      text: target.innerText.replace(/\r/g, ""),
      x: number(target.style.left.replace("px", ""), 0),
      y: number(target.style.top.replace("px", ""), 0),
      width: number(target.style.width.replace("px", ""), 240),
      fontSize: number(target.style.fontSize.replace("px", ""), 18),
      rotation: number(target.dataset.rotation, 0)
    };
  }

  async function commitTarget(target) {
    if (!target) {
      return;
    }
    await bridgeCall(snapshot(target));
  }

  function applySelection(target, notify) {
    selected = target;
    if (moveable) {
      moveable.target = target;
      moveable.draggable = true;
      moveable.resizable = true;
      moveable.rotatable = true;
      moveable.updateRect();
    }
    if (notify && target) {
      bridgeCall({type: "select", id: target.dataset.id});
    }
  }

  function selectTextContents(target) {
    const selection = window.getSelection();
    if (!selection) {
      return;
    }
    const range = document.createRange();
    range.selectNodeContents(target);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  async function finishEditing() {
    if (!editing || finishingEdit) {
      return;
    }
    finishingEdit = true;
    const target = editing;
    editing = null;
    target.contentEditable = "false";
    target.classList.remove("editing");
    await commitTarget(target);
    applySelection(target, false);
    finishingEdit = false;
  }

  async function enterEditing(target) {
    if (editing && editing !== target) {
      await finishEditing();
    }
    selected = target;
    editing = target;
    if (moveable) {
      moveable.target = null;
    }
    target.contentEditable = "true";
    target.classList.add("editing");
    target.focus({preventScroll: true});
    bridgeCall({type: "editStart", id: target.dataset.id});
    if (target.innerText.trim() === "Text") {
      requestAnimationFrame(function () {
        selectTextContents(target);
      });
    }
  }

  function createObject(block) {
    const element = document.createElement("div");
    element.className = "text-object";
    element.dataset.id = block.id;
    element.dataset.rotation = String(number(block.rotation, 0));
    element.contentEditable = "false";
    element.spellcheck = true;
    element.innerText = block.text || "";
    element.style.left = number(block.x, 0) + "px";
    element.style.top = number(block.y, 0) + "px";
    element.style.width = number(block.width, 240) + "px";
    element.style.fontSize = number(block.fontSize, 18) + "px";
    element.style.color = block.color || "#1e1e1e";
    element.style.transform =
      "rotate(" + number(block.rotation, 0) + "deg)";
    element.style.fontFamily = block.fontFamily || "system-ui, sans-serif";
    element.style.fontWeight = block.bold ? "700" : "400";
    element.style.fontStyle = block.italic ? "italic" : "normal";
    element.style.textDecoration =
      (block.underline ? "underline " : "")
      + (block.strike ? "line-through" : "");
    element.style.textAlign = block.align || "left";

    element.addEventListener("dblclick", function (event) {
      event.preventDefault();
      event.stopPropagation();
      enterEditing(element);
    });
    element.addEventListener("blur", function () {
      setTimeout(function () {
        if (editing === element) {
          finishEditing();
        }
      }, 0);
    });
    stage.appendChild(element);
    return element;
  }

  const objects = new Map();
  (initial.blocks || []).forEach(function (block) {
    objects.set(block.id, createObject(block));
  });

  function initMoveable() {
    if (!window.Moveable) {
      bridgeCall({
        type: "engineError",
        message: "Moveable script did not load"
      });
      return;
    }

    moveable = new Moveable(stage, {
      target: null,
      draggable: true,
      resizable: true,
      rotatable: true,
      origin: false,
      edge: false,
      keepRatio: false,
      renderDirections: ["w", "e", "se"],
      rotationPosition: "top",
      throttleDrag: 0,
      throttleResize: 0,
      throttleRotate: 0
    });

    moveable.on("dragStart", function (event) {
      const target = event.target;
      dragStart = {
        x: number(target.style.left.replace("px", ""), 0),
        y: number(target.style.top.replace("px", ""), 0)
      };
    });
    moveable.on("drag", function (event) {
      if (!dragStart) {
        return;
      }
      const delta = event.beforeTranslate || event.translate || [0, 0];
      event.target.style.left = (dragStart.x + delta[0]) + "px";
      event.target.style.top = (dragStart.y + delta[1]) + "px";
    });
    moveable.on("dragEnd", function (event) {
      dragStart = null;
      commitTarget(event.target);
    });

    moveable.on("resizeStart", function (event) {
      const target = event.target;
      resizeStart = {
        x: number(target.style.left.replace("px", ""), 0),
        y: number(target.style.top.replace("px", ""), 0),
        width: number(target.style.width.replace("px", ""), 240),
        fontSize: number(target.style.fontSize.replace("px", ""), 18)
      };
      if (event.dragStart && event.dragStart.set) {
        event.dragStart.set([0, 0]);
      }
    });
    moveable.on("resize", function (event) {
      if (!resizeStart) {
        return;
      }
      const target = event.target;
      const direction = event.direction || [0, 0];
      const isScaleHandle = direction[0] !== 0 && direction[1] !== 0;
      const drag = event.drag || {};
      const delta = drag.beforeTranslate || drag.translate || [0, 0];

      if (isScaleHandle) {
        const scale = Math.max(
          0.25,
          Math.min(4, number(event.width, resizeStart.width) / resizeStart.width)
        );
        target.style.width =
          Math.max(72, Math.min(1200, resizeStart.width * scale)) + "px";
        target.style.fontSize =
          Math.max(8, Math.min(96, resizeStart.fontSize * scale)) + "px";
      } else {
        target.style.width =
          Math.max(72, Math.min(1200, number(event.width, resizeStart.width)))
          + "px";
        target.style.left = (resizeStart.x + delta[0]) + "px";
        target.style.top = (resizeStart.y + delta[1]) + "px";
      }
      moveable.updateRect();
    });
    moveable.on("resizeEnd", function (event) {
      resizeStart = null;
      commitTarget(event.target);
    });

    moveable.on("rotateStart", function (event) {
      const start = number(event.target.dataset.rotation, 0);
      if (event.set) {
        event.set(start);
      }
    });
    moveable.on("rotate", function (event) {
      const angle = number(
        event.beforeRotate === undefined ? event.rotate : event.beforeRotate,
        0
      );
      event.target.dataset.rotation = String(angle);
      event.target.style.transform = "rotate(" + angle + "deg)";
    });
    moveable.on("rotateEnd", function (event) {
      commitTarget(event.target);
    });

    const active = objects.get(initial.activeId);
    if (active) {
      applySelection(active, false);
      if (initial.autoEdit) {
        setTimeout(function () {
          enterEditing(active);
        }, 0);
      }
    }
  }

  stage.addEventListener("pointerdown", function (event) {
    if (
      event.target &&
      event.target.closest &&
      event.target.closest(".moveable-control-box")
    ) {
      return;
    }
    const target =
      event.target && event.target.closest
        ? event.target.closest(".text-object")
        : null;

    if (target) {
      if (editing && editing !== target) {
        finishEditing().then(function () {
          applySelection(target, true);
        });
      } else if (!editing && selected !== target) {
        applySelection(target, true);
      }
      return;
    }

    if (editing) {
      finishEditing().then(function () {
        selected = null;
        if (moveable) {
          moveable.target = null;
        }
        bridgeCall({type: "deselect"});
      });
      return;
    }

    selected = null;
    if (moveable) {
      moveable.target = null;
    }
    bridgeCall({type: "deselect"});
  });

  document.addEventListener("keydown", function (event) {
    if (editing) {
      if (event.key === "Escape") {
        event.preventDefault();
        finishEditing();
      }
      return;
    }
    if (!selected) {
      return;
    }
    if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      const id = selected.dataset.id;
      selected.remove();
      objects.delete(id);
      selected = null;
      if (moveable) {
        moveable.target = null;
      }
      bridgeCall({type: "delete", id: id});
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      selected = null;
      if (moveable) {
        moveable.target = null;
      }
      bridgeCall({type: "deselect"});
    }
  });

  function announceReady() {
    if (window.webview_plus && window.webview_plus.callHandler) {
      bridgeCall({type: "ready"});
      return;
    }
    setTimeout(announceReady, 25);
  }

  initMoveable();
  announceReady();
})();
</script>
</body>
</html>''';
}

class _WebTextStyle {
  const _WebTextStyle({
    required this.fontFamily,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strike,
    required this.align,
  });

  final String? fontFamily;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final String align;

  TextAlign get textAlign => switch (align) {
    'center' => TextAlign.center,
    'right' => TextAlign.right,
    'justify' => TextAlign.justify,
    _ => TextAlign.left,
  };
}
