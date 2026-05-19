import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart'
    show
        PointerPanZoomEndEvent,
        PointerPanZoomStartEvent,
        PointerPanZoomUpdateEvent,
        PointerScrollEvent,
        PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../../editor/presentation/widgets/drawing_canvas.dart';
import '../../editor/presentation/widgets/editor_toolbar.dart';
import '../../editor/presentation/widgets/insert_toolbar.dart';
import '../../editor/presentation/widgets/page_overlay.dart';
import '../../editor/presentation/widgets/text_edit_toolbar.dart';
import '../../editor/state/editor_controller.dart';

class BoardScreen extends StatefulWidget {
  const BoardScreen({super.key});

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  static const double _touchPanSensitivity = 0.55;
  static const double _trackpadPanSensitivity = 0.6;
  static const double _scrollPanSensitivity = 0.38;

  bool _isInsertToolbarVisible = false;
  Offset _insertPosition = const Offset(120, 120);
  final GlobalKey _boardKey = GlobalKey();
  bool _isViewportNavigating = false;
  bool _panZoomSessionActive = false;
  final Map<int, Offset> _activePointers = <int, Offset>{};
  Offset _touchLastFocal = Offset.zero;
  double _touchLastDistance = 1.0;
  Offset _panZoomLastPan = Offset.zero;
  double _panZoomLastScale = 1.0;
  Offset _panZoomLastLocalPosition = Offset.zero;

  Rect _buildBoardRect(EditorController controller, Size viewportSize) {
    final safeScale = controller.viewScale <= 0 ? 1.0 : controller.viewScale;
    final visibleWorldRect = Rect.fromLTWH(
      -controller.viewPan.dx / safeScale,
      -controller.viewPan.dy / safeScale,
      viewportSize.width / safeScale,
      viewportSize.height / safeScale,
    );
    final contentRect = controller.contentBounds.inflate(700);
    final activeRect = visibleWorldRect.inflate(500);
    return Rect.fromLTRB(
      math.min(contentRect.left, activeRect.left),
      math.min(contentRect.top, activeRect.top),
      math.max(contentRect.right, activeRect.right),
      math.max(contentRect.bottom, activeRect.bottom),
    );
  }

  void _onPointerDown(PointerDownEvent event, EditorController controller) {
    if (!_isNavigationPointerKind(event.kind)) {
      return;
    }
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length < 2) {
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _startViewportNavigation(controller);
  }

  void _onPointerMove(PointerMoveEvent event, EditorController controller) {
    if (!_isNavigationPointerKind(event.kind)) {
      return;
    }
    if (!_activePointers.containsKey(event.pointer)) {
      return;
    }
    _activePointers[event.pointer] = event.localPosition;
    if (!_isViewportNavigating) {
      if (_activePointers.length >= 2) {
        _startViewportNavigation(controller);
      }
      return;
    }
    if (_activePointers.length < 2) {
      _stopViewportNavigation();
      return;
    }
    final pointers = _activePointers.values.take(2).toList(growable: false);
    final focal = _midpoint(pointers[0], pointers[1]);
    final distance = _distanceBetween(pointers[0], pointers[1]);
    final previousDistance = _touchLastDistance <= 0 ? 1.0 : _touchLastDistance;
    final scaleDelta = (distance / previousDistance).clamp(0.2, 5.0).toDouble();
    final panDelta = focal - _touchLastFocal;
    _touchLastFocal = focal;
    _touchLastDistance = math.max(0.001, distance);

    if ((scaleDelta - 1.0).abs() > 0.0001) {
      controller.zoomBy(scaleDelta, focalPoint: focal);
    }
    if (panDelta != Offset.zero) {
      controller.panBy(panDelta * _touchPanSensitivity);
    }
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    final removed = _activePointers.remove(event.pointer) != null;
    if (!removed) {
      return;
    }
    if (_activePointers.length >= 2) {
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (_isViewportNavigating && !_panZoomSessionActive) {
      _stopViewportNavigation();
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _startViewportNavigation(EditorController controller) {
    final pointers = _activePointers.values.take(2).toList(growable: false);
    if (pointers.length < 2) {
      return;
    }
    _touchLastFocal = _midpoint(pointers[0], pointers[1]);
    _touchLastDistance = math.max(
      0.001,
      _distanceBetween(pointers[0], pointers[1]),
    );
    if (!_isViewportNavigating) {
      setState(() {
        _isViewportNavigating = true;
      });
    }
  }

  void _onPointerPanZoomStart(
    PointerPanZoomStartEvent event,
    EditorController controller,
  ) {
    _panZoomSessionActive = true;
    _panZoomLastPan = Offset.zero;
    _panZoomLastScale = 1.0;
    _panZoomLastLocalPosition = event.localPosition;
    if (!_isViewportNavigating) {
      setState(() {
        _isViewportNavigating = true;
      });
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _onPointerPanZoomUpdate(
    PointerPanZoomUpdateEvent event,
    EditorController controller,
  ) {
    if (!_panZoomSessionActive) {
      return;
    }
    final fallbackPanDelta = event.pan - _panZoomLastPan;
    final focalDelta = event.localPosition - _panZoomLastLocalPosition;
    final panDelta = event.panDelta != Offset.zero
        ? event.panDelta
        : (fallbackPanDelta != Offset.zero ? fallbackPanDelta : focalDelta);
    final previousGestureScale = _panZoomLastScale == 0
        ? 1.0
        : _panZoomLastScale;
    final scaleDelta = (event.scale / previousGestureScale)
        .clamp(0.2, 5.0)
        .toDouble();
    _panZoomLastPan = event.pan;
    _panZoomLastScale = event.scale;
    _panZoomLastLocalPosition = event.localPosition;

    if ((scaleDelta - 1.0).abs() > 0.0001) {
      controller.zoomBy(scaleDelta, focalPoint: event.localPosition);
    }
    if (panDelta != Offset.zero) {
      controller.panBy(panDelta * _trackpadPanSensitivity);
    }
  }

  void _onPointerPanZoomEnd(PointerPanZoomEndEvent event) {
    _panZoomSessionActive = false;
    if (_activePointers.length >= 2) {
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _stopViewportNavigation();
  }

  void _onPointerSignal(PointerSignalEvent event, EditorController controller) {
    if (event is! PointerScrollEvent) {
      return;
    }
    if (!_isNavigationPointerKind(event.kind)) {
      return;
    }
    if (event.scrollDelta == Offset.zero) {
      return;
    }
    // Trackpad two-finger drag can arrive as scroll signal on Linux.
    controller.panBy(-event.scrollDelta * _scrollPanSensitivity);
  }

  void _fitToContent(EditorController controller, Size viewportSize) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return;
    }
    final content = controller.contentBounds.inflate(120);
    final contentWidth = math.max(1.0, content.width);
    final contentHeight = math.max(1.0, content.height);
    final scaleX = viewportSize.width / contentWidth;
    final scaleY = viewportSize.height / contentHeight;
    final targetScale = math
        .min(scaleX, scaleY)
        .clamp(EditorController.minViewScale, EditorController.maxViewScale)
        .toDouble();
    final viewportCenter = Offset(
      viewportSize.width / 2,
      viewportSize.height / 2,
    );
    final targetPan = viewportCenter - (content.center * targetScale);
    controller.setViewTransform(scale: targetScale, pan: targetPan);
  }

  void _stopViewportNavigation() {
    if (!_isViewportNavigating) {
      return;
    }
    setState(() {
      _isViewportNavigating = false;
    });
  }

  Offset _midpoint(Offset a, Offset b) {
    return Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  }

  double _distanceBetween(Offset a, Offset b) {
    return (a - b).distance;
  }

  bool _isNavigationPointerKind(PointerDeviceKind kind) {
    return kind != PointerDeviceKind.stylus &&
        kind != PointerDeviceKind.invertedStylus;
  }

  Offset _boardInsertPosition(
    Rect boardRect,
    Size viewportSize,
    EditorController controller,
  ) {
    final safeScale = controller.viewScale <= 0 ? 1.0 : controller.viewScale;
    final viewportCenter = Offset(
      viewportSize.width / 2,
      viewportSize.height / 2,
    );
    return (viewportCenter - controller.viewPan) / safeScale;
  }

  Future<void> _handleInsertFile(EditorController controller) async {
    final message = await controller.insertFromFilePicker(_insertPosition);
    if (message != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    controller.setTool(DrawingTool.edit);
  }

  Future<void> _handlePaste(EditorController controller) async {
    final message = await controller.pasteElementOrClipboard(_insertPosition);
    if (message != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _handleCopy(EditorController controller) async {
    final message = await controller.copyActiveElementToClipboard();
    if (message != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _handleCut(EditorController controller) async {
    final message = await controller.cutActiveElementToClipboard();
    if (message != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _handleDelete(EditorController controller) {
    controller.deleteActiveElement();
  }

  Future<void> _showBoardContextMenu(
    Offset globalPosition,
    Rect boardRect,
    EditorController controller,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return;
    }
    final targetPosition = _contextMenuInsertPosition(
      globalPosition: globalPosition,
      boardRect: boardRect,
      controller: controller,
    );
    if (targetPosition != null) {
      _insertPosition = targetPosition;
    }

    final choice = await showMenu<_BoardContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(value: _BoardContextAction.paste, child: Text('Paste')),
      ],
    );

    if (choice == _BoardContextAction.paste) {
      await _handlePaste(controller);
    }
  }

  Offset? _contextMenuInsertPosition({
    required Offset globalPosition,
    required Rect boardRect,
    required EditorController controller,
  }) {
    final renderBox =
        _boardKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return null;
    }
    final local = renderBox.globalToLocal(globalPosition);
    final scale = controller.viewScale <= 0 ? 1.0 : controller.viewScale;
    return (local - controller.viewPan) / scale;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final useWideTitleInset = MediaQuery.sizeOf(context).width >= 600;

    final boardContent = Column(
      children: [
        EditorToolbar(
          controller: controller,
          isInsertOpen: _isInsertToolbarVisible,
          onInsertPressed: () {
            setState(() {
              _isInsertToolbarVisible = !_isInsertToolbarVisible;
            });
          },
        ),
        if (controller.activeTextController != null)
          TextEditToolbar(
            controller: controller.activeTextController!,
            editorController: controller,
            activeTextBlockId: controller.activeTextBlockId,
          ),
        if (_isInsertToolbarVisible)
          InsertToolbar(
            onPickFile: () => _handleInsertFile(controller),
            onPaste: () => _handlePaste(controller),
            onClose: () => setState(() => _isInsertToolbarVisible = false),
          ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.paper,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: AppColors.shadow,
                  blurRadius: 12,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewportSize = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  final boardRect = _buildBoardRect(controller, viewportSize);
                  _insertPosition = _boardInsertPosition(
                    boardRect,
                    viewportSize,
                    controller,
                  );
                  final transformedOffset = Offset(
                    controller.viewPan.dx +
                        (boardRect.left * controller.viewScale),
                    controller.viewPan.dy +
                        (boardRect.top * controller.viewScale),
                  );
                  final transform =
                      Matrix4.diagonal3Values(
                        controller.viewScale,
                        controller.viewScale,
                        1.0,
                      )..setTranslationRaw(
                        transformedOffset.dx,
                        transformedOffset.dy,
                        0.0,
                      );
                  final viewportCenter = Offset(
                    viewportSize.width / 2,
                    viewportSize.height / 2,
                  );

                  return Listener(
                    key: _boardKey,
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) => _onPointerDown(event, controller),
                    onPointerMove: (event) => _onPointerMove(event, controller),
                    onPointerUp: (event) => _onPointerUpOrCancel(event),
                    onPointerCancel: (event) => _onPointerUpOrCancel(event),
                    onPointerPanZoomStart: (event) =>
                        _onPointerPanZoomStart(event, controller),
                    onPointerPanZoomUpdate: (event) =>
                        _onPointerPanZoomUpdate(event, controller),
                    onPointerPanZoomEnd: _onPointerPanZoomEnd,
                    onPointerSignal: (event) =>
                        _onPointerSignal(event, controller),
                    child: GestureDetector(
                      onSecondaryTapDown: (details) => _showBoardContextMenu(
                        details.globalPosition,
                        boardRect,
                        controller,
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: 0,
                              minHeight: 0,
                              maxWidth: double.infinity,
                              maxHeight: double.infinity,
                              child: Transform(
                                transform: transform,
                                child: SizedBox(
                                  width: boardRect.width,
                                  height: boardRect.height,
                                  child: Stack(
                                    children: [
                                      DrawingCanvas(
                                        allowMultiTouch: false,
                                        interactionEnabled:
                                            !_isViewportNavigating,
                                        worldOrigin: boardRect.topLeft,
                                      ),
                                      PageOverlay(
                                        controller: controller,
                                        interactionEnabled:
                                            !_isViewportNavigating,
                                        worldOrigin: boardRect.topLeft,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: _BoardZoomControls(
                              zoomPercent: (controller.viewScale * 100).round(),
                              onZoomIn: () => controller.zoomBy(
                                1.15,
                                focalPoint: viewportCenter,
                              ),
                              onZoomOut: () => controller.zoomBy(
                                1 / 1.15,
                                focalPoint: viewportCenter,
                              ),
                              onFitView: () =>
                                  _fitToContent(controller, viewportSize),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );

    final shortcutsEnabled = controller.activeTextController == null;
    final content = shortcutsEnabled
        ? Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.keyV, control: true):
                  _PasteFromClipboardIntent(),
              SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                  _PasteFromClipboardIntent(),
              SingleActivator(LogicalKeyboardKey.keyC, control: true):
                  _CopyElementIntent(),
              SingleActivator(LogicalKeyboardKey.keyC, meta: true):
                  _CopyElementIntent(),
              SingleActivator(LogicalKeyboardKey.keyX, control: true):
                  _CutElementIntent(),
              SingleActivator(LogicalKeyboardKey.keyX, meta: true):
                  _CutElementIntent(),
              SingleActivator(LogicalKeyboardKey.delete):
                  _DeleteElementIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _PasteFromClipboardIntent: CallbackAction<Intent>(
                  onInvoke: (_) {
                    _handlePaste(controller);
                    return null;
                  },
                ),
                _CopyElementIntent: CallbackAction<Intent>(
                  onInvoke: (_) {
                    _handleCopy(controller);
                    return null;
                  },
                ),
                _CutElementIntent: CallbackAction<Intent>(
                  onInvoke: (_) {
                    _handleCut(controller);
                    return null;
                  },
                ),
                _DeleteElementIntent: CallbackAction<Intent>(
                  onInvoke: (_) {
                    _handleDelete(controller);
                    return null;
                  },
                ),
              },
              child: Focus(autofocus: true, child: boardContent),
            ),
          )
        : boardContent;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: useWideTitleInset ? 44 : null,
        title: Text(controller.notebook.title),
      ),
      body: content,
    );
  }
}

enum _BoardContextAction { paste }

class _PasteFromClipboardIntent extends Intent {
  const _PasteFromClipboardIntent();
}

class _CopyElementIntent extends Intent {
  const _CopyElementIntent();
}

class _CutElementIntent extends Intent {
  const _CutElementIntent();
}

class _DeleteElementIntent extends Intent {
  const _DeleteElementIntent();
}

class _BoardZoomControls extends StatelessWidget {
  const _BoardZoomControls({
    required this.zoomPercent,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFitView,
  });

  final int zoomPercent;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFitView;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.toolbar.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove),
              tooltip: 'Zoom out',
              onPressed: onZoomOut,
            ),
            SizedBox(
              width: 54,
              child: Text(
                '$zoomPercent%',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add),
              tooltip: 'Zoom in',
              onPressed: onZoomIn,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.fit_screen),
              tooltip: 'Fit all content',
              onPressed: onFitView,
            ),
          ],
        ),
      ),
    );
  }
}
