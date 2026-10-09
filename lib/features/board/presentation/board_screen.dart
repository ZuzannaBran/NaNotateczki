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
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../../core/diagnostics/board_scene_perf_tracker.dart';
import '../../../core/theme/app_colors.dart';
import '../../editor/presentation/editor_commands.dart';
import '../../editor/presentation/editor_settings_screen.dart';
import '../../editor/presentation/widgets/busy_overlay.dart';
import '../../editor/presentation/widgets/drawing_canvas.dart';
import '../../editor/presentation/widgets/editor_toolbar.dart';
import '../../editor/presentation/widgets/page_background_paint.dart';
import '../../editor/presentation/widgets/page_overlay.dart';
import '../../editor/presentation/widgets/text_edit_toolbar.dart';
import '../../editor/state/editor_controller.dart';
import '../../notebook/domain/drawing_tool.dart';

class BoardScreen extends StatefulWidget {
  const BoardScreen({super.key, this.showToolbar = true});

  final bool showToolbar;

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  static const double _touchPanSensitivity = 0.55;
  static const double _trackpadPanSensitivity = 0.6;
  static const double _scrollPanSensitivity = 0.38;
  static const double _inkNavigationTouchSlop = 8.0;

  Offset _insertPosition = const Offset(120, 120);
  final BoardSceneBoundsResolver _sceneBounds = BoardSceneBoundsResolver();
  final GlobalKey _boardKey = GlobalKey();
  bool _isViewportNavigating = false;
  bool _panZoomSessionActive = false;
  bool _isBusy = false;
  final Map<int, Offset> _activePointers = <int, Offset>{};
  int? _activeInkPointer;
  int? _pendingNavigationPointer;
  Offset? _pendingNavigationPosition;
  Offset _touchLastFocal = Offset.zero;
  double _touchLastDistance = 1.0;
  Offset _panZoomLastPan = Offset.zero;
  double _panZoomLastScale = 1.0;
  Offset _panZoomLastLocalPosition = Offset.zero;

  Rect _buildBoardRect(EditorController controller, Size viewportSize) {
    return _sceneBounds.resolve(
      contentBounds: controller.contentBounds,
      viewPan: controller.viewPan,
      viewScale: controller.viewScale,
      viewportSize: viewportSize,
      freeze: controller.isObjectTransformActive,
    );
  }

  void _onPointerDown(PointerDownEvent event, EditorController controller) {
    if (controller.isObjectTransformActive) {
      return;
    }
    if (controller.tool.isInk && _isStylusPointerKind(event.kind)) {
      _activeInkPointer = event.pointer;
      _pendingNavigationPointer = null;
      _pendingNavigationPosition = null;
      return;
    }
    if (controller.tool.isInk &&
        event.kind == PointerDeviceKind.touch &&
        _activeInkPointer != null) {
      return;
    }
    if (!_isNavigationPointerKind(event.kind)) {
      return;
    }
    if (controller.tool.isInk && event.kind == PointerDeviceKind.touch) {
      if (!controller.allowsFingerDrawing) {
        _activePointers[event.pointer] = event.localPosition;
        _startViewportNavigation(controller);
        return;
      }
      if (_pendingNavigationPointer == null && _activePointers.isEmpty) {
        _pendingNavigationPointer = event.pointer;
        _pendingNavigationPosition = event.localPosition;
        return;
      }
      final pendingPointer = _pendingNavigationPointer;
      final pendingPosition = _pendingNavigationPosition;
      if (pendingPointer != null && pendingPosition != null) {
        _activePointers[pendingPointer] = pendingPosition;
        _pendingNavigationPointer = null;
        _pendingNavigationPosition = null;
      }
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
    if (controller.isObjectTransformActive) {
      if (event.pointer == _pendingNavigationPointer) {
        _pendingNavigationPointer = null;
        _pendingNavigationPosition = null;
      }
      _activePointers.remove(event.pointer);
      return;
    }
    if (event.pointer == _activeInkPointer) {
      return;
    }
    if (event.kind == PointerDeviceKind.touch && _activeInkPointer != null) {
      return;
    }
    if (!_isNavigationPointerKind(event.kind)) {
      return;
    }
    if (event.pointer == _pendingNavigationPointer) {
      final pendingPosition = _pendingNavigationPosition;
      if (pendingPosition != null &&
          (event.localPosition - pendingPosition).distance >
              _inkNavigationTouchSlop) {
        _pendingNavigationPointer = null;
        _pendingNavigationPosition = null;
      }
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
      if (event.kind == PointerDeviceKind.touch &&
          !controller.allowsFingerDrawing &&
          _activePointers.length == 1) {
        final panDelta = event.localPosition - _touchLastFocal;
        _touchLastFocal = event.localPosition;
        _touchLastDistance = 1.0;
        if (panDelta != Offset.zero) {
          controller.panBy(panDelta * _touchPanSensitivity);
        }
        return;
      }
      _stopViewportNavigation(controller);
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

    if (controller.isPinchToScaleImageActive) {
      final safeScale = controller.viewScale <= 0 ? 1.0 : controller.viewScale;
      controller.updatePinchToScaleActiveImage(
        scaleDelta,
        panDelta * _touchPanSensitivity / safeScale,
      );
      return;
    }

    if ((scaleDelta - 1.0).abs() > 0.0001) {
      controller.zoomBy(scaleDelta, focalPoint: focal);
    }
    if (panDelta != Offset.zero) {
      controller.panBy(panDelta * _touchPanSensitivity);
    }
  }

  void _onPointerUpOrCancel(PointerEvent event, EditorController controller) {
    if (event.pointer == _activeInkPointer) {
      _activeInkPointer = null;
      return;
    }
    if (event.pointer == _pendingNavigationPointer) {
      _pendingNavigationPointer = null;
      _pendingNavigationPosition = null;
      return;
    }
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
    if (_isViewportNavigating &&
        !_panZoomSessionActive &&
        _activePointers.length == 1 &&
        !controller.allowsFingerDrawing) {
      _touchLastFocal = _activePointers.values.first;
      _touchLastDistance = 1.0;
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (_isViewportNavigating && !_panZoomSessionActive) {
      _stopViewportNavigation(controller);
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _startViewportNavigation(EditorController controller) {
    final pointers = _activePointers.values.take(2).toList(growable: false);
    if (pointers.isEmpty) {
      return;
    }
    if (pointers.length >= 2) {
      controller.startPinchToScaleActiveImage();
      _touchLastFocal = _midpoint(pointers[0], pointers[1]);
      _touchLastDistance = math.max(
        0.001,
        _distanceBetween(pointers[0], pointers[1]),
      );
    } else {
      _touchLastFocal = pointers[0];
      _touchLastDistance = 1.0;
    }
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
    if (controller.isObjectTransformActive) {
      return;
    }
    controller.startPinchToScaleActiveImage();
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

    if (controller.isPinchToScaleImageActive) {
      final safeScale = controller.viewScale <= 0 ? 1.0 : controller.viewScale;
      controller.updatePinchToScaleActiveImage(
        scaleDelta,
        panDelta * _trackpadPanSensitivity / safeScale,
      );
      return;
    }

    if ((scaleDelta - 1.0).abs() > 0.0001) {
      controller.zoomBy(scaleDelta, focalPoint: event.localPosition);
    }
    if (panDelta != Offset.zero) {
      controller.panBy(panDelta * _trackpadPanSensitivity);
    }
  }

  void _onPointerPanZoomEnd(
    PointerPanZoomEndEvent event,
    EditorController controller,
  ) {
    _panZoomSessionActive = false;
    controller.endPinchToScaleActiveImage();
    if (_activePointers.length >= 2) {
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _stopViewportNavigation(controller);
  }

  void _onPointerSignal(PointerSignalEvent event, EditorController controller) {
    if (controller.isObjectTransformActive) {
      return;
    }
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

  void _stopViewportNavigation(EditorController controller) {
    controller.endPinchToScaleActiveImage();
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

  bool _isStylusPointerKind(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
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

  Future<T> _withBusyOverlay<T>(Future<T> Function() action) async {
    if (mounted) {
      setState(() => _isBusy = true);
    }
    try {
      return await action();
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  EditorCommands _commands(EditorController controller) => EditorCommands(
    context: context,
    controller: controller,
    insertPosition: () => _insertPosition,
    runBusy: _withBusyOverlay,
  );

  void _openSettings() {
    final controller = context.read<EditorController>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChangeNotifierProvider.value(
          value: controller,
          child: const EditorSettingsScreen(),
        ),
      ),
    );
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

    if (choice == _BoardContextAction.paste && mounted) {
      await _commands(controller).paste();
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
    final activeTextBlockId = controller.activeTextBlockId;
    final activeTextBlock = activeTextBlockId == null
        ? null
        : controller.findTextBlockById(activeTextBlockId);

    final commands = _commands(controller);

    final boardContent = Stack(
      children: [
        Positioned.fill(
          child: Container(
            key: const ValueKey('board-canvas-area'),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppColors.darkPaper
                  : AppColors.paper,
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
                  final buildStopwatch = Stopwatch()..start();
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

                  final child = Listener(
                    key: _boardKey,
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) => _onPointerDown(event, controller),
                    onPointerMove: (event) => _onPointerMove(event, controller),
                    onPointerUp: (event) =>
                        _onPointerUpOrCancel(event, controller),
                    onPointerCancel: (event) =>
                        _onPointerUpOrCancel(event, controller),
                    onPointerPanZoomStart: (event) =>
                        _onPointerPanZoomStart(event, controller),
                    onPointerPanZoomUpdate: (event) =>
                        _onPointerPanZoomUpdate(event, controller),
                    onPointerPanZoomEnd: (event) =>
                        _onPointerPanZoomEnd(event, controller),
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
                            child: _BoardPaintProbe(
                              layerName: 'scenePaint',
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
                                        Positioned.fill(
                                          child: _BoardPaintProbe(
                                            layerName: 'backgroundPaint',
                                            child: PageBackgroundPaint(
                                              settings: controller
                                                  .currentBackgroundSettings,
                                              origin: boardRect.topLeft,
                                            ),
                                          ),
                                        ),
                                        _BoardPaintProbe(
                                          layerName: 'inactiveOverlayPaint',
                                          child: PageOverlay(
                                            controller: controller,
                                            interactionEnabled:
                                                !_isViewportNavigating,
                                            worldOrigin: boardRect.topLeft,
                                            renderBackground: true,
                                            renderInactive: true,
                                            renderActive: false,
                                          ),
                                        ),
                                        _BoardPaintProbe(
                                          layerName: 'canvasHostPaint',
                                          child: DrawingCanvas(
                                            allowMultiTouch: false,
                                            interactionEnabled:
                                                !_isViewportNavigating,
                                            worldOrigin: boardRect.topLeft,
                                            effectiveScale:
                                                controller.viewScale,
                                          ),
                                        ),
                                        _BoardPaintProbe(
                                          layerName: 'activeOverlayPaint',
                                          child: PageOverlay(
                                            controller: controller,
                                            interactionEnabled:
                                                !_isViewportNavigating,
                                            worldOrigin: boardRect.topLeft,
                                            renderBackground: false,
                                            renderInactive: false,
                                            renderActive: true,
                                          ),
                                        ),
                                      ],
                                    ),
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
                  buildStopwatch.stop();
                  BoardScenePerfTracker.instance.recordBuild(
                    buildStopwatch.elapsedMicroseconds,
                  );
                  return child;
                },
              ),
            ),
          ),
        ),
        if (widget.showToolbar)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                EditorToolbar(
                  controller: controller,
                  onInsertPressed: commands.insertFile,
                  onExportSelected: commands.export,
                ),
                if (activeTextBlock != null)
                  TextEditToolbar(
                    editorController: controller,
                    block: activeTextBlock,
                  ),
              ],
            ),
          ),
      ],
    );

    final content = EditorCommandShortcuts(
      commands: commands,
      enabled: controller.activeTextController == null,
      child: boardContent,
    );

    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleSpacing: useWideTitleInset ? 44 : null,
        title: Text(controller.notebook.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: content),
          if (_isBusy) const Positioned.fill(child: BusyOverlay()),
        ],
      ),
    );
  }
}

/// Keeps the board's local coordinate origin stable while an object is
/// being moved or resized. The scene can be recalculated between gestures.
class BoardSceneBoundsResolver {
  Rect? _lastRect;
  Rect? _frozenRect;

  Rect resolve({
    required Rect contentBounds,
    required Offset viewPan,
    required double viewScale,
    required Size viewportSize,
    required bool freeze,
  }) {
    final safeScale = viewScale <= 0 ? 1.0 : viewScale;
    final visibleWorldRect = Rect.fromLTWH(
      -viewPan.dx / safeScale,
      -viewPan.dy / safeScale,
      viewportSize.width / safeScale,
      viewportSize.height / safeScale,
    );
    final contentRect = contentBounds.inflate(700);
    final activeRect = visibleWorldRect.inflate(500);
    final resolved = Rect.fromLTRB(
      math.min(contentRect.left, activeRect.left),
      math.min(contentRect.top, activeRect.top),
      math.max(contentRect.right, activeRect.right),
      math.max(contentRect.bottom, activeRect.bottom),
    );

    if (freeze) {
      return _frozenRect ??= _lastRect ?? resolved;
    }
    _frozenRect = null;
    _lastRect = resolved;
    return resolved;
  }
}

class _BoardPaintProbe extends SingleChildRenderObjectWidget {
  const _BoardPaintProbe({required this.layerName, required super.child});

  final String layerName;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderBoardPaintProbe(layerName);
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final paintProbe = renderObject as _RenderBoardPaintProbe;
    paintProbe.layerName = layerName;
  }
}

class _RenderBoardPaintProbe extends RenderProxyBox {
  _RenderBoardPaintProbe(this._layerName);

  String _layerName;

  set layerName(String value) {
    _layerName = value;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final stopwatch = Stopwatch()..start();
    super.paint(context, offset);
    stopwatch.stop();
    BoardScenePerfTracker.instance.recordPaint(
      _layerName,
      stopwatch.elapsedMicroseconds,
    );
  }
}

enum _BoardContextAction { paste }

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
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerLow.withValues(alpha: 0.92),
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
