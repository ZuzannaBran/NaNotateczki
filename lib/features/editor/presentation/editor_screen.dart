import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
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
import '../../../core/theme/app_metrics.dart';
import '../../../data/export/notebook_export_service.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/note_page.dart';
import '../state/editor_controller.dart';
import 'widgets/drawing_canvas.dart';
import 'widgets/editor_toolbar.dart';
import 'widgets/page_overlay.dart';
import 'widgets/text_edit_toolbar.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  static const double _pageGap = 26;
  static const double _leftMargin = 56;
  static const double _rightMargin = 56;
  static const double _topBottomPadding = 22;
  static const double _addPageButtonGap = 10;
  static const double _addPageFooterHeight = 56;
  static const double _minPageScaleFactor = 0.25;
  static const double _maxPageScaleFloor = 1.8;
  static const double _postFitZoomFactor = 2.0;
  static const double _touchPanSensitivity = 0.55;
  static const double _trackpadPanSensitivity = 0.6;
  static const double _scrollPanSensitivity = 0.38;
  static const double _inkNavigationTouchSlop = 8.0;
  static const double _previewColumnRight = 118.0;
  static const double _edgeStopTolerance = 0.5;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _canvasKey = GlobalKey();
  double _pageExtent = 0;
  bool _isViewportNavigating = false;
  bool _panZoomSessionActive = false;
  final Map<int, Offset> _activePointers = <int, Offset>{};
  int? _activeInkPointer;
  int? _pendingNavigationPointer;
  Offset? _pendingNavigationPosition;
  Offset _touchLastFocal = Offset.zero;
  double _touchLastDistance = 1.0;
  Offset _panZoomLastPan = Offset.zero;
  double _panZoomLastScale = 1.0;
  Offset _panZoomLastLocalPosition = Offset.zero;
  double _pageScale = 1.0;
  Offset _pagePan = Offset.zero;
  double _pageMinScale = 1.0;
  double _pageMaxScale = 1.0;
  double _pageColumnOffset = 0.0;
  double _pageColumnMinOffset = 0.0;
  double _pageColumnMaxOffset = _rightMargin;
  Offset _insertPosition = const Offset(120, 120);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  bool _onPagesScroll(
    ScrollNotification notification,
    EditorController controller,
  ) {
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }

    if (notification is ScrollEndNotification) {
      _syncCurrentPageToViewport(controller);
    }

    return false;
  }

  void _syncCurrentPageToViewport(EditorController controller) {
    // While zoomed-in navigation is active, keep the interaction page stable.
    // Auto-switching currentPage here can replace the active gesture target
    // with a preview card and make the editor feel frozen.
    if (_pageScale > 1.001 || _isViewportNavigating || _panZoomSessionActive) {
      return;
    }
    if (!_scrollController.hasClients || _pageExtent <= 0) {
      return;
    }
    if (controller.pages.isEmpty) {
      return;
    }
    final raw =
        ((_scrollController.position.pixels + (_pageExtent * 0.45)) /
                _pageExtent)
            .floor();
    final target = raw.clamp(0, controller.pages.length - 1);
    if (target != controller.currentPageIndex) {
      controller.setCurrentPage(target);
    }
  }

  void _addPageBelow(EditorController controller) {
    controller.addPage();
  }

  void _syncPageTransformBounds({
    required Size docWorldSize,
    required double fitToWidthScale,
    required Size viewportSize,
  }) {
    if (docWorldSize.width <= 0 || docWorldSize.height <= 0) {
      return;
    }
    _pageMinScale = _minPageScaleFactor;
    final widthBasedLimit = fitToWidthScale * _postFitZoomFactor;
    _pageMaxScale = math
        .max(_maxPageScaleFloor, widthBasedLimit)
        .clamp(1.0, 3.0)
        .toDouble();
    final clampedScale = _pageScale
        .clamp(_pageMinScale, _pageMaxScale)
        .toDouble();
    final clampedPan = _clampPagePan(
      scale: clampedScale,
      pan: _pagePan,
      docWorldSize: docWorldSize,
      viewportSize: viewportSize,
    );
    if (clampedScale == _pageScale && clampedPan == _pagePan) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pageScale = clampedScale;
        _pagePan = clampedPan;
      });
    });
  }

  void _syncPageColumnOffsetBounds({required double basePageLeft}) {
    final minOffset = math.min(0.0, _previewColumnRight - basePageLeft);
    final maxOffset = _rightMargin;
    _pageColumnMinOffset = minOffset;
    _pageColumnMaxOffset = maxOffset;
    final clampedOffset = _pageColumnOffset
        .clamp(minOffset, maxOffset)
        .toDouble();
    if (clampedOffset == _pageColumnOffset) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pageColumnOffset = clampedOffset;
      });
    });
  }

  void _applyPageColumnPan(double deltaX) {
    if (deltaX.abs() < _edgeStopTolerance) {
      return;
    }
    if (_pageColumnOffset <= _pageColumnMinOffset + _edgeStopTolerance &&
        deltaX < 0) {
      _snapPageColumnToEdge(_pageColumnMinOffset);
      return;
    }
    if (_pageColumnOffset >= _pageColumnMaxOffset - _edgeStopTolerance &&
        deltaX > 0) {
      _snapPageColumnToEdge(_pageColumnMaxOffset);
      return;
    }
    final nextOffset = (_pageColumnOffset + deltaX)
        .clamp(_pageColumnMinOffset, _pageColumnMaxOffset)
        .toDouble();
    final snappedOffset = _snapToPageColumnEdge(nextOffset);
    if ((snappedOffset - _pageColumnOffset).abs() < _edgeStopTolerance) {
      return;
    }
    setState(() {
      _pageColumnOffset = snappedOffset;
    });
  }

  double _snapToPageColumnEdge(double offset) {
    if ((offset - _pageColumnMinOffset).abs() < _edgeStopTolerance) {
      return _pageColumnMinOffset;
    }
    if ((offset - _pageColumnMaxOffset).abs() < _edgeStopTolerance) {
      return _pageColumnMaxOffset;
    }
    return offset;
  }

  void _snapPageColumnToEdge(double edge) {
    if ((_pageColumnOffset - edge).abs() < 0.01) {
      return;
    }
    setState(() {
      _pageColumnOffset = edge;
    });
  }

  bool _isNavigationPointerKind(PointerDeviceKind kind) {
    return kind != PointerDeviceKind.stylus &&
        kind != PointerDeviceKind.invertedStylus;
  }

  bool _isStylusPointerKind(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  void _onPointerDown(
    PointerDownEvent event,
    Size docWorldSize,
    Size viewportSize,
  ) {
    final controller = context.read<EditorController>();
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
      return;
    }
    _startViewportNavigation(docWorldSize, viewportSize);
  }

  void _onPointerMove(
    PointerMoveEvent event,
    Size docWorldSize,
    Size viewportSize,
  ) {
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
        _activePointers[event.pointer] = event.localPosition;
        _pendingNavigationPointer = null;
        _pendingNavigationPosition = null;
        if (_activePointers.length >= 2) {
          _startViewportNavigation(docWorldSize, viewportSize);
        }
      }
      return;
    }
    if (!_activePointers.containsKey(event.pointer)) {
      return;
    }
    _activePointers[event.pointer] = event.localPosition;
    if (!_isViewportNavigating) {
      if (_activePointers.length >= 2) {
        _startViewportNavigation(docWorldSize, viewportSize);
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
    final scaleDelta = (distance / previousDistance)
        .clamp(0.25, 4.0)
        .toDouble();
    final panDelta = focal - _touchLastFocal;
    _touchLastFocal = focal;
    _touchLastDistance = math.max(0.001, distance);

    final controller = context.read<EditorController>();
    if (controller.isPinchToScaleImageActive) {
      final safeScale = _pageScale <= 0 ? 1.0 : _pageScale;
      controller.updatePinchToScaleActiveImage(
        scaleDelta,
        panDelta * _touchPanSensitivity / safeScale,
      );
      return;
    }

    final adjustedPanDelta = Offset(0, panDelta.dy);
    _applyPageColumnPan(panDelta.dx * _touchPanSensitivity);
    _applyPageTransform(
      scaleDelta: scaleDelta,
      panDelta: adjustedPanDelta * _touchPanSensitivity,
      focalPoint: focal,
      docWorldSize: docWorldSize,
      viewportSize: viewportSize,
    );
  }

  void _onPointerUpOrCancel(PointerEvent event) {
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
      return;
    }
    if (_isViewportNavigating && !_panZoomSessionActive) {
      _stopViewportNavigation();
      if (mounted) {
        _syncCurrentPageToViewport(context.read<EditorController>());
      }
    }
  }

  void _startViewportNavigation(Size docWorldSize, Size viewportSize) {
    final pointers = _activePointers.values.take(2).toList(growable: false);
    if (pointers.length < 2) {
      return;
    }
    context.read<EditorController>().startPinchToScaleActiveImage();
    _touchLastFocal = _midpoint(pointers[0], pointers[1]);
    _touchLastDistance = math.max(
      0.001,
      _distanceBetween(pointers[0], pointers[1]),
    );
    final clampedPan = _clampPagePan(
      scale: _pageScale,
      pan: _pagePan,
      docWorldSize: docWorldSize,
      viewportSize: viewportSize,
    );
    if (_isViewportNavigating && clampedPan == _pagePan) {
      return;
    }
    setState(() {
      _isViewportNavigating = true;
      _pagePan = clampedPan;
    });
  }

  void _onPointerPanZoomStart(
    PointerPanZoomStartEvent event,
    Size docWorldSize,
    Size viewportSize,
  ) {
    context.read<EditorController>().startPinchToScaleActiveImage();
    _panZoomSessionActive = true;
    _panZoomLastPan = Offset.zero;
    _panZoomLastScale = 1.0;
    _panZoomLastLocalPosition = event.localPosition;
    final clampedPan = _clampPagePan(
      scale: _pageScale,
      pan: _pagePan,
      docWorldSize: docWorldSize,
      viewportSize: viewportSize,
    );
    if (_isViewportNavigating && clampedPan == _pagePan) {
      return;
    }
    setState(() {
      _isViewportNavigating = true;
      _pagePan = clampedPan;
    });
  }

  void _onPointerPanZoomUpdate(
    PointerPanZoomUpdateEvent event,
    Size docWorldSize,
    Size viewportSize,
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
        .clamp(0.25, 4.0)
        .toDouble();
    _panZoomLastPan = event.pan;
    _panZoomLastScale = event.scale;
    _panZoomLastLocalPosition = event.localPosition;

    final controller = context.read<EditorController>();
    if (controller.isPinchToScaleImageActive) {
      final safeScale = _pageScale <= 0 ? 1.0 : _pageScale;
      controller.updatePinchToScaleActiveImage(
        scaleDelta,
        panDelta * _trackpadPanSensitivity / safeScale,
      );
      return;
    }

    _applyPageTransform(
      scaleDelta: scaleDelta,
      panDelta: panDelta * _trackpadPanSensitivity,
      focalPoint: event.localPosition,
      docWorldSize: docWorldSize,
      viewportSize: viewportSize,
    );
  }

  void _onPointerPanZoomEnd(PointerPanZoomEndEvent event) {
    _panZoomSessionActive = false;
    context.read<EditorController>().endPinchToScaleActiveImage();
    if (_activePointers.length >= 2) {
      return;
    }
    _stopViewportNavigation();
    if (mounted) {
      _syncCurrentPageToViewport(context.read<EditorController>());
    }
  }

  void _onPointerSignal(
    PointerSignalEvent event,
    Size docWorldSize,
    Size viewportSize,
  ) {
    if (event is! PointerScrollEvent) {
      return;
    }
    if (!_isNavigationPointerKind(event.kind)) {
      return;
    }
    if (event.scrollDelta == Offset.zero) {
      return;
    }
    // Linux trackpads often emit scroll signals for two-finger panning.
    _applyPageTransform(
      scaleDelta: 1.0,
      panDelta: -event.scrollDelta * _scrollPanSensitivity,
      focalPoint: event.localPosition,
      docWorldSize: docWorldSize,
      viewportSize: viewportSize,
    );
  }

  void _applyPageTransform({
    required double scaleDelta,
    required Offset panDelta,
    required Offset focalPoint,
    required Size docWorldSize,
    required Size viewportSize,
  }) {
    final currentScale = _pageScale <= 0 ? 1.0 : _pageScale;
    final targetScale = (currentScale * scaleDelta)
        .clamp(_pageMinScale, _pageMaxScale)
        .toDouble();

    var desiredPan = _pagePan;
    if ((targetScale - currentScale).abs() > 0.0001) {
      final worldAtFocal = (focalPoint - _pagePan) / currentScale;
      desiredPan = focalPoint - (worldAtFocal * targetScale);
    }
    if (panDelta != Offset.zero) {
      desiredPan += panDelta;
    }
    final clampedPan = _clampPagePan(
      scale: targetScale,
      pan: desiredPan,
      docWorldSize: docWorldSize,
      viewportSize: viewportSize,
    );

    final overflow = desiredPan - clampedPan;
    if (overflow.dy.abs() > 0.01 && _scrollController.hasClients) {
      final position = _scrollController.position;
      final targetOffset = (position.pixels - overflow.dy)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      if ((targetOffset - position.pixels).abs() > 0.5) {
        _scrollController.jumpTo(targetOffset);
      }
    }

    if (targetScale == _pageScale && clampedPan == _pagePan) {
      return;
    }

    setState(() {
      _pageScale = targetScale;
      _pagePan = clampedPan;
    });
  }

  Offset _clampPagePan({
    required double scale,
    required Offset pan,
    required Size docWorldSize,
    required Size viewportSize,
  }) {
    final contentWidth = docWorldSize.width * scale;
    final contentHeight = docWorldSize.height * scale;

    late final double minX;
    late final double maxX;
    if (contentWidth <= viewportSize.width) {
      final centeredX = (viewportSize.width - contentWidth) / 2;
      minX = centeredX;
      maxX = centeredX;
    } else {
      minX = viewportSize.width - contentWidth;
      maxX = 0.0;
    }

    late final double minY;
    late final double maxY;
    if (contentHeight <= viewportSize.height) {
      final centeredY = (viewportSize.height - contentHeight) / 2;
      minY = centeredY;
      maxY = centeredY;
    } else {
      minY = viewportSize.height - contentHeight;
      maxY = 0.0;
    }

    final clampedX = pan.dx.clamp(minX, maxX).toDouble();
    final clampedY = pan.dy.clamp(minY, maxY).toDouble();
    return Offset(clampedX, clampedY);
  }

  void _stopViewportNavigation() {
    context.read<EditorController>().endPinchToScaleActiveImage();
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

  double _documentHeight({required double pageHeight, required int pageCount}) {
    if (pageCount <= 0) {
      return pageHeight;
    }
    return (pageCount * pageHeight) + (math.max(0, pageCount - 1) * _pageGap);
  }

  Rect _visibleDocumentRect({
    required Size docWorldSize,
    required Size viewportSize,
  }) {
    final docHeight = docWorldSize.height;
    final safeScale = _pageScale <= 0 ? 1.0 : _pageScale;

    var clipTop = 0.0;
    var clipBottom = viewportSize.height;
    if (_scrollController.hasClients) {
      final metrics = _scrollController.position;
      clipTop = metrics.pixels - _topBottomPadding;
      clipBottom =
          metrics.pixels + metrics.viewportDimension - _topBottomPadding;
    }

    final worldLeft = ((-_pagePan.dx) / safeScale).clamp(
      0.0,
      docWorldSize.width,
    );
    final worldRight = ((viewportSize.width - _pagePan.dx) / safeScale).clamp(
      0.0,
      docWorldSize.width,
    );
    final worldTop = ((clipTop - _pagePan.dy) / safeScale).clamp(
      0.0,
      docHeight,
    );
    final worldBottom = ((clipBottom - _pagePan.dy) / safeScale).clamp(
      0.0,
      docHeight,
    );

    final width = math.max(1.0, worldRight - worldLeft);
    final height = math.max(1.0, worldBottom - worldTop);

    return Rect.fromLTWH(worldLeft, worldTop, width, height);
  }

  _BoundaryVisibility _pageBoundaryVisibilityInDocument({
    required Rect visibleDocumentRect,
    required Size pageWorldSize,
    required int pageIndex,
  }) {
    const edgeThreshold = 1.0;
    final pageTop = pageIndex * (pageWorldSize.height + _pageGap);
    final pageBottom = pageTop + pageWorldSize.height;
    final pageRect = Rect.fromLTWH(
      0,
      pageTop,
      pageWorldSize.width,
      pageWorldSize.height,
    );

    if (!pageRect.overlaps(visibleDocumentRect)) {
      return const _BoundaryVisibility(
        left: false,
        top: false,
        right: false,
        bottom: false,
      );
    }

    final pageFullyVisible =
        visibleDocumentRect.left <= pageRect.left + edgeThreshold &&
        visibleDocumentRect.top <= pageRect.top + edgeThreshold &&
        visibleDocumentRect.right >= pageRect.right - edgeThreshold &&
        visibleDocumentRect.bottom >= pageRect.bottom - edgeThreshold;
    if (pageFullyVisible) {
      return const _BoundaryVisibility(
        left: true,
        top: true,
        right: true,
        bottom: true,
      );
    }

    final touchesLeft = visibleDocumentRect.left <= edgeThreshold;
    final touchesRight =
        visibleDocumentRect.right >= pageWorldSize.width - edgeThreshold;
    final touchesTop =
        visibleDocumentRect.top <= pageTop + edgeThreshold &&
        visibleDocumentRect.bottom >= pageTop - edgeThreshold;
    final touchesBottom =
        visibleDocumentRect.bottom >= pageBottom - edgeThreshold &&
        visibleDocumentRect.top <= pageBottom + edgeThreshold;

    return _BoundaryVisibility(
      left: touchesLeft,
      top: touchesTop,
      right: touchesRight,
      bottom: touchesBottom,
    );
  }

  _PageRenderRange _visiblePageRange({
    required Rect visibleDocumentRect,
    required Size pageWorldSize,
    required int pageCount,
    required int currentPageIndex,
  }) {
    return _PageRenderRange(0, math.max(0, pageCount));
  }

  Offset _insertPositionForViewport({
    required Rect visibleDocumentRect,
    required Size pageWorldSize,
    required int currentPageIndex,
  }) {
    final pageTop =
        currentPageIndex.toDouble() * (_pageExtent == 0 ? 1 : _pageExtent);
    final pageRect = Rect.fromLTWH(
      0,
      pageTop,
      pageWorldSize.width,
      pageWorldSize.height,
    );
    final safeRect = visibleDocumentRect.intersect(pageRect);
    if (safeRect.isEmpty) {
      return Offset(
        pageWorldSize.width * 0.5,
        pageTop + pageWorldSize.height * 0.5,
      );
    }
    return safeRect.center;
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

  Future<void> _handleExport(
    EditorController controller,
    NotebookExportFormat format,
  ) async {
    try {
      final path = await NotebookExportService.exportController(
        controller,
        format,
      );
      if (!mounted) {
        return;
      }
      if (path == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Export cancelled')));
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Exported to $path')));
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
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

  Future<void> _showIndexTabEditor(
    EditorController controller,
    int pageIndex,
    String tabId,
  ) async {
    if (pageIndex < 0 || pageIndex >= controller.pages.length) {
      return;
    }
    final page = controller.pages[pageIndex];
    final tab = page.indexTabs.where((tab) => tab.id == tabId).firstOrNull;
    if (tab == null) {
      return;
    }
    final currentColor = tab.color;
    var red = _toByte(currentColor.r).toDouble();
    var green = _toByte(currentColor.g).toDouble();
    var blue = _toByte(currentColor.b).toDouble();
    var position = tab.position.clamp(0.0, 1.0).toDouble();

    final result = await showDialog<_IndexTabEditResult>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final preview = Color.fromARGB(
              255,
              red.round(),
              green.round(),
              blue.round(),
            );
            return AlertDialog(
              title: const Text('Edit tab'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 172,
                    child: Row(
                      children: [
                        Container(
                          width: 92,
                          height: 160,
                          decoration: BoxDecoration(
                            color: AppColors.paper,
                            border: Border.all(color: AppColors.divider),
                            boxShadow: const [
                              BoxShadow(
                                color: AppColors.shadow,
                                blurRadius: 8,
                                offset: Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                left: -28,
                                top: 8 + position * 136,
                                width: 56,
                                height: 16,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: preview.withValues(alpha: 0.75),
                                    borderRadius: const BorderRadius.only(
                                      topLeft: Radius.circular(2),
                                      bottomLeft: Radius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Slider(
                            value: position,
                            min: 0,
                            max: 1,
                            divisions: 20,
                            onChanged: (value) =>
                                setDialogState(() => position = value),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _indexTabChannelSlider(
                    label: 'R',
                    value: red,
                    color: Colors.red,
                    onChanged: (value) => setDialogState(() => red = value),
                  ),
                  _indexTabChannelSlider(
                    label: 'G',
                    value: green,
                    color: Colors.green,
                    onChanged: (value) => setDialogState(() => green = value),
                  ),
                  _indexTabChannelSlider(
                    label: 'B',
                    value: blue,
                    color: Colors.blue,
                    onChanged: (value) => setDialogState(() => blue = value),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(_IndexTabEditResult.remove()),
                  child: const Text('Remove'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    _IndexTabEditResult.save(
                      color: preview,
                      position: position,
                    ),
                  ),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) {
      return;
    }
    controller.setCurrentPage(pageIndex);
    if (result.remove) {
      controller.clearIndexTab(tabId);
      return;
    }
    controller.updateIndexTab(
      id: tabId,
      color: result.color,
      position: result.position,
    );
  }

  Widget _indexTabChannelSlider({
    required String label,
    required double value,
    required Color color,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 18, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            activeColor: color,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  int _toByte(double component) {
    return (component * 255.0).round().clamp(0, 255).toInt();
  }

  Future<void> _showCanvasContextMenu(
    Offset globalPosition,
    EditorController controller,
    Size docWorldSize,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return;
    }
    final targetPosition = _contextMenuInsertPosition(
      globalPosition: globalPosition,
      docWorldSize: docWorldSize,
    );
    if (targetPosition != null) {
      _insertPosition = targetPosition;
      if (_pageExtent > 0 && controller.pages.isNotEmpty) {
        final pageIndex = (_insertPosition.dy / _pageExtent).floor().clamp(
          0,
          controller.pages.length - 1,
        );
        controller.setCurrentPage(pageIndex);
      }
    }

    final choice = await showMenu<_CanvasContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(value: _CanvasContextAction.paste, child: Text('Paste')),
      ],
    );

    if (choice == _CanvasContextAction.paste) {
      await _handlePaste(controller);
    }
  }

  Offset? _contextMenuInsertPosition({
    required Offset globalPosition,
    required Size docWorldSize,
  }) {
    final renderBox =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return null;
    }
    final local = renderBox.globalToLocal(globalPosition);
    final scale = _pageScale <= 0 ? 1.0 : _pageScale;
    final world = (local - _pagePan) / scale;
    return Offset(
      world.dx.clamp(0.0, docWorldSize.width),
      world.dy.clamp(0.0, docWorldSize.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final useWideTitleInset = MediaQuery.sizeOf(context).width >= 600;

    final editorContent = Column(
      children: [
        EditorToolbar(
          controller: controller,
          onInsertPressed: () => _handleInsertFile(controller),
          onExportSelected: (format) => _handleExport(controller, format),
        ),
        if (controller.activeTextController != null)
          TextEditToolbar(
            controller: controller.activeTextController!,
            editorController: controller,
            activeTextBlockId: controller.activeTextBlockId,
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxPageWidth = math.max(
                260.0,
                constraints.maxWidth - (_leftMargin + _rightMargin),
              );
              final pageWidth = math.min(820.0, maxPageWidth);
              final pageHeight = pageWidth * AppMetrics.a4HeightRatio;
              final pageWorldSize = Size(pageWidth, pageHeight);
              controller.updatePageLayout(
                pageWidth: pageWorldSize.width,
                pageHeight: pageWorldSize.height,
                pageGap: _pageGap,
              );
              final docHeight = _documentHeight(
                pageHeight: pageWorldSize.height,
                pageCount: controller.pages.length,
              );
              final docWorldSize = Size(pageWorldSize.width, docHeight);
              final fitToWidthScale = (maxPageWidth / pageWidth)
                  .clamp(1.0, 4.0)
                  .toDouble();
              final clipScale = math.max(
                1.0,
                math.min(_pageScale, fitToWidthScale),
              );
              final clipSize = Size(
                docWorldSize.width * clipScale,
                docWorldSize.height * clipScale,
              );
              final documentContentSize = Size(
                clipSize.width,
                clipSize.height + (_addPageFooterHeight * clipScale),
              );
              final basePageLeft =
                  constraints.maxWidth -
                  _rightMargin -
                  documentContentSize.width;
              final viewportSize = Size(
                clipSize.width,
                math.max(1.0, constraints.maxHeight - (_topBottomPadding * 2)),
              );
              final zoomPercent = (_pageScale * 100).round();
              final visibleDocumentRect = _visibleDocumentRect(
                docWorldSize: docWorldSize,
                viewportSize: viewportSize,
              );
              final visiblePageRange = _visiblePageRange(
                visibleDocumentRect: visibleDocumentRect,
                pageWorldSize: pageWorldSize,
                pageCount: controller.pages.length,
                currentPageIndex: controller.currentPageIndex,
              );
              final insertPosition = _insertPositionForViewport(
                visibleDocumentRect: visibleDocumentRect,
                pageWorldSize: pageWorldSize,
                currentPageIndex: controller.currentPageIndex,
              );
              _insertPosition = insertPosition;
              final minimapPanelHeight = math.min(
                pageWorldSize.height * 0.5,
                math.max(180.0, constraints.maxHeight - 24),
              );
              _pageExtent = pageWorldSize.height + _pageGap;
              _syncPageColumnOffsetBounds(basePageLeft: basePageLeft);
              _syncPageTransformBounds(
                docWorldSize: docWorldSize,
                fitToWidthScale: fitToWidthScale,
                viewportSize: viewportSize,
              );
              final pageTransform = Matrix4.diagonal3Values(
                _pageScale,
                _pageScale,
                1.0,
              )..setTranslationRaw(_pagePan.dx, _pagePan.dy, 0.0);

              return Container(
                color: AppColors.paper.withValues(alpha: 0.35),
                child: Stack(
                  children: [
                    NotificationListener<ScrollNotification>(
                      onNotification: (notification) =>
                          _onPagesScroll(notification, controller),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics:
                            (controller.tool.isInk ||
                                _isViewportNavigating ||
                                _pageScale > 1.001)
                            ? const NeverScrollableScrollPhysics()
                            : const ClampingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(
                          _leftMargin,
                          _topBottomPadding,
                          _rightMargin,
                          _topBottomPadding,
                        ),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Transform.translate(
                            offset: Offset(_pageColumnOffset, 0),
                            child: SizedBox(
                              width: documentContentSize.width,
                              height: documentContentSize.height,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  SizedBox(
                                    width: clipSize.width,
                                    height: clipSize.height,
                                    child: ClipRect(
                                      child: GestureDetector(
                                        onSecondaryTapDown: (details) =>
                                            _showCanvasContextMenu(
                                              details.globalPosition,
                                              controller,
                                              docWorldSize,
                                            ),
                                        child: Listener(
                                          key: _canvasKey,
                                          behavior: HitTestBehavior.translucent,
                                          onPointerDown: (event) =>
                                              _onPointerDown(
                                                event,
                                                docWorldSize,
                                                viewportSize,
                                              ),
                                          onPointerMove: (event) =>
                                              _onPointerMove(
                                                event,
                                                docWorldSize,
                                                viewportSize,
                                              ),
                                          onPointerUp: _onPointerUpOrCancel,
                                          onPointerCancel: _onPointerUpOrCancel,
                                          onPointerPanZoomStart: (event) =>
                                              _onPointerPanZoomStart(
                                                event,
                                                docWorldSize,
                                                viewportSize,
                                              ),
                                          onPointerPanZoomUpdate: (event) =>
                                              _onPointerPanZoomUpdate(
                                                event,
                                                docWorldSize,
                                                viewportSize,
                                              ),
                                          onPointerPanZoomEnd:
                                              _onPointerPanZoomEnd,
                                          onPointerSignal: (event) =>
                                              _onPointerSignal(
                                                event,
                                                docWorldSize,
                                                viewportSize,
                                              ),
                                          child: Transform(
                                            alignment: Alignment.topLeft,
                                            transform: pageTransform,
                                            child: SizedBox(
                                              width: docWorldSize.width,
                                              height: docWorldSize.height,
                                              child: Stack(
                                                children: [
                                                  for (
                                                    var i =
                                                        visiblePageRange.start;
                                                    i < visiblePageRange.end;
                                                    i++
                                                  )
                                                    Positioned(
                                                      left: 0,
                                                      top: i * _pageExtent,
                                                      width:
                                                          pageWorldSize.width,
                                                      height:
                                                          pageWorldSize.height,
                                                      child: IgnorePointer(
                                                        child: Stack(
                                                          fit: StackFit.expand,
                                                          children: [
                                                            DecoratedBox(
                                                              decoration: BoxDecoration(
                                                                color: AppColors
                                                                    .paper,
                                                                boxShadow: const [
                                                                  BoxShadow(
                                                                    color: AppColors
                                                                        .shadow,
                                                                    blurRadius:
                                                                        14,
                                                                    offset:
                                                                        Offset(
                                                                          0,
                                                                          6,
                                                                        ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                            Builder(
                                                              builder: (context) {
                                                                final visibility = _pageBoundaryVisibilityInDocument(
                                                                  visibleDocumentRect:
                                                                      visibleDocumentRect,
                                                                  pageWorldSize:
                                                                      pageWorldSize,
                                                                  pageIndex: i,
                                                                );
                                                                return CustomPaint(
                                                                  painter: _PageFramePainter(
                                                                    showLeft:
                                                                        visibility
                                                                            .left,
                                                                    showTop:
                                                                        visibility
                                                                            .top,
                                                                    showRight:
                                                                        visibility
                                                                            .right,
                                                                    showBottom:
                                                                        visibility
                                                                            .bottom,
                                                                    highlightColor: Theme.of(context)
                                                                        .colorScheme
                                                                        .primary
                                                                        .withValues(
                                                                          alpha:
                                                                              0.75,
                                                                        ),
                                                                  ),
                                                                );
                                                              },
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  DocumentPageOverlay(
                                                    controller: controller,
                                                    interactionEnabled:
                                                        !_isViewportNavigating,
                                                    worldOrigin: Offset.zero,
                                                    pages: controller.pages,
                                                    pageSize: pageWorldSize,
                                                    pageGap: _pageGap,
                                                    firstPageIndex:
                                                        visiblePageRange.start,
                                                    lastPageIndex:
                                                        visiblePageRange.end,
                                                    renderBackground: true,
                                                    renderInactive: true,
                                                    renderActive: false,
                                                  ),
                                                  DocumentDrawingCanvas(
                                                    allowMultiTouch: false,
                                                    interactionEnabled:
                                                        !_isViewportNavigating,
                                                    worldOrigin: Offset.zero,
                                                    pages: controller.pages,
                                                    pageSize: pageWorldSize,
                                                    pageGap: _pageGap,
                                                    firstPageIndex:
                                                        visiblePageRange.start,
                                                    lastPageIndex:
                                                        visiblePageRange.end,
                                                  ),
                                                  DocumentPageOverlay(
                                                    controller: controller,
                                                    interactionEnabled:
                                                        !_isViewportNavigating,
                                                    worldOrigin: Offset.zero,
                                                    pages: controller.pages,
                                                    pageSize: pageWorldSize,
                                                    pageGap: _pageGap,
                                                    firstPageIndex:
                                                        visiblePageRange.start,
                                                    lastPageIndex:
                                                        visiblePageRange.end,
                                                    renderBackground: false,
                                                    renderInactive: false,
                                                    renderActive: true,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Transform(
                                    alignment: Alignment.topLeft,
                                    transform: pageTransform,
                                    child: _IndexTabsOverlay(
                                      pages: controller.pages,
                                      pageSize: pageWorldSize,
                                      pageGap: _pageGap,
                                      firstPageIndex: visiblePageRange.start,
                                      lastPageIndex: visiblePageRange.end,
                                      onEditTab: (pageIndex, tabId) =>
                                          _showIndexTabEditor(
                                            controller,
                                            pageIndex,
                                            tabId,
                                          ),
                                      onDragStart: (pageIndex, tabId) =>
                                          controller.beginIndexTabDrag(
                                            pageIndex: pageIndex,
                                            id: tabId,
                                          ),
                                      onDragUpdate: (tabId, position) =>
                                          controller.updateIndexTabDrag(
                                            id: tabId,
                                            position: position,
                                          ),
                                      onDragEnd: controller.commitIndexTabDrag,
                                    ),
                                  ),
                                  Transform(
                                    alignment: Alignment.topLeft,
                                    transform: pageTransform,
                                    child: SizedBox(
                                      width: docWorldSize.width,
                                      height:
                                          docWorldSize.height +
                                          _addPageFooterHeight,
                                      child: Stack(
                                        children: [
                                          Positioned(
                                            top:
                                                docWorldSize.height +
                                                _addPageButtonGap,
                                            left: 0,
                                            width: docWorldSize.width,
                                            child: Center(
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  FilledButton.icon(
                                                    onPressed: () =>
                                                        _addPageBelow(
                                                          controller,
                                                        ),
                                                    icon: const Icon(Icons.add),
                                                    label: const Text(
                                                      'Add page',
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  OutlinedButton.icon(
                                                    onPressed:
                                                        controller
                                                                .pages
                                                                .length >
                                                            1
                                                        ? controller
                                                              .deleteLastPage
                                                        : null,
                                                    icon: const Icon(
                                                      Icons.delete_outline,
                                                    ),
                                                    label: const Text(
                                                      'Delete page',
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
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
                      top: 10,
                      right: 12,
                      child: IgnorePointer(
                        child: _ZoomPercentBadge(zoomPercent: zoomPercent),
                      ),
                    ),
                    Positioned(
                      top: 10,
                      left: 10,
                      child: _ProjectMiniMapOverlay(
                        pages: controller.pages,
                        currentPageIndex: controller.currentPageIndex,
                        pageWorldSize: pageWorldSize,
                        pageGap: _pageGap,
                        panelHeight: minimapPanelHeight,
                        visibleDocumentRect: visibleDocumentRect,
                      ),
                    ),
                  ],
                ),
              );
            },
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
              child: Focus(autofocus: true, child: editorContent),
            ),
          )
        : editorContent;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: useWideTitleInset ? 44 : null,
        title: Text(controller.notebook.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_outline),
            tooltip: 'Bookmark page',
            onPressed: controller.toggleBookmark,
          ),
        ],
      ),
      body: content,
    );
  }
}

class _PasteFromClipboardIntent extends Intent {
  const _PasteFromClipboardIntent();
}

class _IndexTabEditResult {
  const _IndexTabEditResult({
    required this.color,
    required this.position,
    required this.remove,
  });

  final Color color;
  final double position;
  final bool remove;

  factory _IndexTabEditResult.save({
    required Color color,
    required double position,
  }) {
    return _IndexTabEditResult(color: color, position: position, remove: false);
  }

  factory _IndexTabEditResult.remove() {
    return const _IndexTabEditResult(
      color: Colors.transparent,
      position: 0,
      remove: true,
    );
  }
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

enum _CanvasContextAction { paste }

class _BoundaryVisibility {
  const _BoundaryVisibility({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final bool left;
  final bool top;
  final bool right;
  final bool bottom;

  bool get any => left || top || right || bottom;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is _BoundaryVisibility &&
        other.left == left &&
        other.top == top &&
        other.right == right &&
        other.bottom == bottom;
  }

  @override
  int get hashCode {
    return Object.hash(left, top, right, bottom);
  }
}

class _PageRenderRange {
  const _PageRenderRange(this.start, this.end);

  final int start;
  final int end;
}

class _PageFramePainter extends CustomPainter {
  _PageFramePainter({
    required this.showLeft,
    required this.showTop,
    required this.showRight,
    required this.showBottom,
    required this.highlightColor,
  });

  final bool showLeft;
  final bool showTop;
  final bool showRight;
  final bool showBottom;
  final Color highlightColor;

  @override
  void paint(Canvas canvas, Size size) {
    const highlightStroke = 1.8;

    if (!(showLeft || showTop || showRight || showBottom)) {
      return;
    }

    final edgePaint = Paint()
      ..color = highlightColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = highlightStroke
      ..strokeCap = StrokeCap.round;
    final inset = highlightStroke / 2;
    final leftX = inset;
    final topY = inset;
    final rightX = size.width - inset;
    final bottomY = size.height - inset;
    const capInset = 0.0;

    if (showTop) {
      canvas.drawLine(
        Offset(leftX + capInset, topY),
        Offset(rightX - capInset, topY),
        edgePaint,
      );
    }
    if (showBottom) {
      canvas.drawLine(
        Offset(leftX + capInset, bottomY),
        Offset(rightX - capInset, bottomY),
        edgePaint,
      );
    }
    if (showLeft) {
      canvas.drawLine(
        Offset(leftX, topY + capInset),
        Offset(leftX, bottomY - capInset),
        edgePaint,
      );
    }
    if (showRight) {
      canvas.drawLine(
        Offset(rightX, topY + capInset),
        Offset(rightX, bottomY - capInset),
        edgePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PageFramePainter oldDelegate) {
    return oldDelegate.showLeft != showLeft ||
        oldDelegate.showTop != showTop ||
        oldDelegate.showRight != showRight ||
        oldDelegate.showBottom != showBottom ||
        oldDelegate.highlightColor != highlightColor;
  }
}

class _IndexTabsOverlay extends StatefulWidget {
  const _IndexTabsOverlay({
    required this.pages,
    required this.pageSize,
    required this.pageGap,
    required this.firstPageIndex,
    required this.lastPageIndex,
    required this.onEditTab,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  static const double _tabWidth = 92;
  static const double _tabHeight = 24;
  static const double _tabOverhang = _tabWidth / 2;

  final List<NotePage> pages;
  final Size pageSize;
  final double pageGap;
  final int firstPageIndex;
  final int lastPageIndex;
  final void Function(int pageIndex, String tabId) onEditTab;
  final void Function(int pageIndex, String tabId) onDragStart;
  final void Function(String tabId, double position) onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<_IndexTabsOverlay> createState() => _IndexTabsOverlayState();
}

class _IndexTabsOverlayState extends State<_IndexTabsOverlay> {
  double? _dragStartPosition;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.pageSize.width,
      height:
          widget.pages.length * widget.pageSize.height +
          math.max(0, widget.pages.length - 1) * widget.pageGap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = widget.firstPageIndex; i < widget.lastPageIndex; i++)
            for (final tab in widget.pages[i].indexTabs)
              Positioned(
                left: -_IndexTabsOverlay._tabOverhang,
                top:
                    i * (widget.pageSize.height + widget.pageGap) +
                    _tabTop(tab.position),
                width: _IndexTabsOverlay._tabWidth,
                height: _IndexTabsOverlay._tabHeight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => widget.onEditTab(i, tab.id),
                  onLongPressStart: (_) {
                    _dragStartPosition = tab.position;
                    widget.onDragStart(i, tab.id);
                  },
                  onLongPressMoveUpdate: (details) {
                    final available = math.max(
                      1.0,
                      widget.pageSize.height - _IndexTabsOverlay._tabHeight,
                    );
                    final startPosition = _dragStartPosition ?? tab.position;
                    final position =
                        startPosition + details.offsetFromOrigin.dy / available;
                    widget.onDragUpdate(tab.id, position);
                  },
                  onLongPressEnd: (_) {
                    _dragStartPosition = null;
                    widget.onDragEnd();
                  },
                  onLongPressCancel: () {
                    _dragStartPosition = null;
                    widget.onDragEnd();
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tab.color,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(2),
                        bottomLeft: Radius.circular(2),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: AppColors.shadow,
                          blurRadius: 6,
                          offset: Offset(-1, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  double _tabTop(double? position) {
    final available = math.max(
      0.0,
      widget.pageSize.height - _IndexTabsOverlay._tabHeight,
    );
    return available * (position ?? 0).clamp(0.0, 1.0).toDouble();
  }
}

class _ZoomPercentBadge extends StatelessWidget {
  const _ZoomPercentBadge({required this.zoomPercent});

  final int zoomPercent;

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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          '$zoomPercent%',
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    );
  }
}

class _ProjectMiniMapOverlay extends StatefulWidget {
  const _ProjectMiniMapOverlay({
    required this.pages,
    required this.currentPageIndex,
    required this.pageWorldSize,
    required this.pageGap,
    required this.panelHeight,
    required this.visibleDocumentRect,
  });

  final List<NotePage> pages;
  final int currentPageIndex;
  final Size pageWorldSize;
  final double pageGap;
  final double panelHeight;
  final Rect visibleDocumentRect;

  @override
  State<_ProjectMiniMapOverlay> createState() => _ProjectMiniMapOverlayState();
}

class _ProjectMiniMapOverlayState extends State<_ProjectMiniMapOverlay> {
  static const double _minimapWidth = 84.0;

  final ScrollController _minimapScrollController = ScrollController();
  final Map<String, _MiniMapImageCacheEntry> _minimapImages = {};
  final Set<String> _loadingMinimapImageIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncMinimapToViewport();
      _precacheMinimapImages();
    });
  }

  @override
  void didUpdateWidget(covariant _ProjectMiniMapOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_minimapScrollController.hasClients) {
        _precacheMinimapImages();
        return;
      }
      final max = _minimapScrollController.position.maxScrollExtent;
      if (_minimapScrollController.offset > max) {
        _minimapScrollController.jumpTo(max);
      }
      _syncMinimapToViewport();
      _precacheMinimapImages();
    });
  }

  void _precacheMinimapImages() {
    final activeIds = <String>{};
    for (final page in widget.pages) {
      for (final block in page.imageBlocks) {
        activeIds.add(block.id);
        final cacheKey = _minimapImageCacheKey(block);
        final cached = _minimapImages[block.id];
        if (cached != null && cached.cacheKey == cacheKey) {
          continue;
        }
        if (_loadingMinimapImageIds.contains(block.id)) {
          continue;
        }
        _loadMinimapImage(block, cacheKey);
      }
    }

    final obsoleteIds = _minimapImages.keys
        .where((id) => !activeIds.contains(id))
        .toList();
    for (final id in obsoleteIds) {
      _minimapImages.remove(id)?.image.dispose();
    }
  }

  Future<void> _loadMinimapImage(ImageBlock block, String cacheKey) async {
    _loadingMinimapImageIds.add(block.id);
    ui.Image? image;
    try {
      image = await _decodeMinimapImage(block);
      if (!mounted) {
        image?.dispose();
        return;
      }
      final currentKey = _currentMinimapImageCacheKey(block.id);
      if (image == null || currentKey != cacheKey) {
        image?.dispose();
        return;
      }
      _minimapImages.remove(block.id)?.image.dispose();
      _minimapImages[block.id] = _MiniMapImageCacheEntry(
        cacheKey: cacheKey,
        image: image,
      );
      image = null;
      setState(() {});
    } catch (error) {
      debugPrint('_ProjectMiniMapOverlay: failed to decode image: $error');
    } finally {
      image?.dispose();
      _loadingMinimapImageIds.remove(block.id);
    }
  }

  String? _currentMinimapImageCacheKey(String id) {
    for (final page in widget.pages) {
      for (final block in page.imageBlocks) {
        if (block.id == id) {
          return _minimapImageCacheKey(block);
        }
      }
    }
    return null;
  }

  String _minimapImageCacheKey(ImageBlock block) {
    return [
      block.id,
      block.path,
      block.bytes?.lengthInBytes ?? 0,
      block.imageExt ?? '',
      block.imageMime ?? '',
    ].join('|');
  }

  Future<ui.Image?> _decodeMinimapImage(ImageBlock block) async {
    Uint8List? bytes = block.bytes;
    if ((bytes == null || bytes.isEmpty) && block.path.isNotEmpty) {
      final file = File(block.path);
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      }
    }
    if (bytes == null || bytes.isEmpty) {
      return null;
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    buffer.dispose();
    descriptor.dispose();
    codec.dispose();
    return frame.image;
  }

  void _syncMinimapToViewport() {
    if (!mounted || !_minimapScrollController.hasClients) {
      return;
    }
    final worldWidth = math.max(1.0, widget.pageWorldSize.width);
    final mapScale = _minimapWidth / worldWidth;
    final panelHeight = _visiblePanelHeight(mapScale);

    final indicatorTop = widget.visibleDocumentRect.top * mapScale;
    final indicatorBottom = widget.visibleDocumentRect.bottom * mapScale;
    final viewTop = _minimapScrollController.offset;
    final viewBottom = viewTop + panelHeight;
    final margin = panelHeight * 0.18;

    double? target;
    if (indicatorTop < viewTop + margin) {
      target = indicatorTop - margin;
    } else if (indicatorBottom > viewBottom - margin) {
      target = indicatorBottom - panelHeight + margin;
    }

    if (target == null) {
      return;
    }

    final clamped = target
        .clamp(0.0, _minimapScrollController.position.maxScrollExtent)
        .toDouble();
    if ((clamped - _minimapScrollController.offset).abs() < 1.0) {
      return;
    }
    _minimapScrollController.jumpTo(clamped);
  }

  double _visiblePanelHeight(double mapScale) {
    return math.min(widget.panelHeight, _contentHeight(mapScale));
  }

  double _contentHeight(double mapScale) {
    return math.max(1.0, _documentWorldHeight() * mapScale);
  }

  double _documentWorldHeight() {
    return math.max(
      1.0,
      (widget.pages.length * widget.pageWorldSize.height) +
          (math.max(0, widget.pages.length - 1) * widget.pageGap),
    );
  }

  @override
  void dispose() {
    _minimapScrollController.dispose();
    for (final cached in _minimapImages.values) {
      cached.image.dispose();
    }
    _minimapImages.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const outerRadius = 10.0;
    const minimapPadding = 6.0;
    const innerRadius = outerRadius - minimapPadding;
    final worldWidth = math.max(1.0, widget.pageWorldSize.width);
    final mapScale = _minimapWidth / worldWidth;
    final contentHeight = _contentHeight(mapScale);
    final panelHeight = _visiblePanelHeight(mapScale);
    final canScroll = contentHeight > panelHeight + 0.5;
    final indicatorRectInContent = Rect.fromLTWH(
      widget.visibleDocumentRect.left * mapScale,
      widget.visibleDocumentRect.top * mapScale,
      widget.visibleDocumentRect.width * mapScale,
      math.max(3.0, widget.visibleDocumentRect.height * mapScale),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.toolbar.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(outerRadius),
        boxShadow: const [
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(minimapPadding),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(innerRadius),
          child: SizedBox(
            width: _minimapWidth,
            height: panelHeight,
            child: Stack(
              children: [
                SingleChildScrollView(
                  controller: _minimapScrollController,
                  physics: canScroll
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size(_minimapWidth, contentHeight),
                      painter: _ProjectMiniMapPainter(
                        pages: widget.pages,
                        currentPageIndex: widget.currentPageIndex,
                        pageWorldSize: widget.pageWorldSize,
                        pageGap: widget.pageGap,
                        mapScale: mapScale,
                        cornerRadius: innerRadius,
                        images: _minimapImages.map(
                          (id, cached) => MapEntry(id, cached.image),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _minimapScrollController,
                      builder: (context, child) {
                        final scrollOffset = _minimapScrollController.hasClients
                            ? _minimapScrollController.offset
                            : 0.0;
                        final rect = indicatorRectInContent
                            .shift(Offset(0, -scrollOffset))
                            .intersect(
                              Rect.fromLTWH(0, 0, _minimapWidth, panelHeight),
                            );
                        return CustomPaint(
                          painter: _MiniMapViewportOverlayPainter(
                            indicatorRect: rect,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectMiniMapPainter extends CustomPainter {
  _ProjectMiniMapPainter({
    required this.pages,
    required this.currentPageIndex,
    required this.pageWorldSize,
    required this.pageGap,
    required this.mapScale,
    required this.cornerRadius,
    required this.images,
  });

  final List<NotePage> pages;
  final int currentPageIndex;
  final Size pageWorldSize;
  final double pageGap;
  final double mapScale;
  final double cornerRadius;
  final Map<String, ui.Image> images;

  @override
  void paint(Canvas canvas, Size size) {
    final panelRect = Offset.zero & size;
    final panelRRect = RRect.fromRectAndRadius(
      panelRect,
      Radius.circular(cornerRadius),
    );
    final background = Paint()..color = const Color(0xFFF8FAFD);
    canvas.drawRRect(panelRRect, background);

    final border = Paint()
      ..color = const Color(0xFFCFD7E4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(panelRRect.deflate(0.5), border);

    if (pages.isEmpty) {
      return;
    }

    final worldWidth = math.max(1.0, pageWorldSize.width);
    final scaleX = size.width / worldWidth;
    final scaleY = mapScale;

    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final pageTopWorld = i * (pageWorldSize.height + pageGap);
      final pageTop = pageTopWorld * scaleY;
      final pageHeight = pageWorldSize.height * scaleY;
      final pageRect = Rect.fromLTWH(0, pageTop, size.width, pageHeight);
      final isCurrentPage = i == currentPageIndex;

      final pageFill = Paint()..color = const Color(0xFFFDFEFF);
      final pageBorder = Paint()
        ..color = isCurrentPage
            ? const Color(0xFFC8D2E0)
            : const Color(0xFFD4DCE8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isCurrentPage ? 0.7 : 0.6;
      canvas.drawRect(pageRect, pageFill);
      canvas.drawRect(pageRect.deflate(0.3), pageBorder);

      for (final tab in page.indexTabs) {
        final stripeHeight = (pageHeight * 0.035).clamp(2.0, 7.0).toDouble();
        final stripeTop =
            pageTop +
            (pageHeight - stripeHeight) * tab.position.clamp(0.0, 1.0);
        final stripePaint = Paint()..color = tab.color.withValues(alpha: 0.34);
        canvas.drawRect(
          Rect.fromLTWH(0, stripeTop, size.width, stripeHeight),
          stripePaint,
        );
      }

      if (pageGap > 0 && i < pages.length - 1) {
        final separator = Paint()..color = const Color(0xFFE4EAF2);
        final sepTop = (pageTopWorld + pageWorldSize.height) * scaleY;
        final sepHeight = (pageGap * scaleY).clamp(0.5, 3.0).toDouble();
        canvas.drawRect(
          Rect.fromLTWH(0, sepTop, size.width, sepHeight),
          separator,
        );
      }

      Offset toMap(Offset point) =>
          Offset(point.dx * scaleX, (pageTopWorld + point.dy) * scaleY);

      canvas.save();
      canvas.clipRect(pageRect);

      final imageFill = Paint()..color = const Color(0xFFE6ECF5);
      final imageBorder = Paint()
        ..color = const Color(0xFFB7C2D0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.55;
      for (final block in page.imageBlocks) {
        final image = images[block.id];
        final rect = _imageRect(block, pageTopWorld, scaleX, scaleY);
        if (image == null) {
          canvas.drawRect(rect, imageFill);
        } else {
          final crop = Rect.fromLTRB(
            block.cropLeft.clamp(0.0, 1.0) * image.width,
            block.cropTop.clamp(0.0, 1.0) * image.height,
            block.cropRight.clamp(0.0, 1.0) * image.width,
            block.cropBottom.clamp(0.0, 1.0) * image.height,
          );
          if (block.rotation == 0) {
            canvas.drawImageRect(image, crop, rect, Paint());
          } else {
            canvas.save();
            canvas.translate(rect.center.dx, rect.center.dy);
            canvas.rotate(block.rotation);
            canvas.translate(-rect.center.dx, -rect.center.dy);
            canvas.drawImageRect(image, crop, rect, Paint());
            canvas.restore();
          }
        }
        canvas.drawRect(rect, imageBorder);
      }

      final textPaint = Paint()..color = const Color(0xFF95A2B4);
      for (final block in page.textBlocks) {
        final topLeft = toMap(block.position + const Offset(0, 2));
        final lineWidth = (block.width * scaleX * 0.8)
            .clamp(6.0, size.width * 0.84)
            .toDouble();
        final lineHeight = math.max(1.0, block.fontSize * scaleY * 0.18);
        canvas.drawRect(
          Rect.fromLTWH(topLeft.dx, topLeft.dy, lineWidth, lineHeight),
          textPaint,
        );
      }

      for (final stroke in page.inkStrokes) {
        if (stroke.points.isEmpty) {
          continue;
        }
        final paint = Paint()
          ..color = stroke.tool.name == 'highlighter'
              ? stroke.color.withValues(alpha: 0.24)
              : stroke.color.withValues(alpha: 0.88)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = (stroke.width * ((scaleX + scaleY) / 2)).clamp(
            0.38,
            1.45,
          );

        if (stroke.points.length == 1) {
          final point = toMap(stroke.points.first.toOffset());
          canvas.drawCircle(point, paint.strokeWidth / 2, paint);
          continue;
        }

        final path = Path();
        final first = toMap(stroke.points.first.toOffset());
        path.moveTo(first.dx, first.dy);
        for (var j = 1; j < stroke.points.length; j++) {
          final point = toMap(stroke.points[j].toOffset());
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ProjectMiniMapPainter oldDelegate) {
    return oldDelegate.pages != pages ||
        oldDelegate.currentPageIndex != currentPageIndex ||
        oldDelegate.pageWorldSize != pageWorldSize ||
        oldDelegate.pageGap != pageGap ||
        oldDelegate.mapScale != mapScale ||
        oldDelegate.cornerRadius != cornerRadius ||
        oldDelegate.images != images;
  }

  Rect _imageRect(
    ImageBlock block,
    double pageTopWorld,
    double scaleX,
    double scaleY,
  ) {
    final visibleWidth =
        block.width * (block.cropRight - block.cropLeft).clamp(0.08, 1.0);
    final visibleHeight =
        block.height * (block.cropBottom - block.cropTop).clamp(0.08, 1.0);
    return Rect.fromLTWH(
      (block.position.dx + block.width * block.cropLeft) * scaleX,
      (pageTopWorld + block.position.dy + block.height * block.cropTop) *
          scaleY,
      visibleWidth * scaleX,
      visibleHeight * scaleY,
    );
  }
}

class _MiniMapImageCacheEntry {
  const _MiniMapImageCacheEntry({required this.cacheKey, required this.image});

  final String cacheKey;
  final ui.Image image;
}

class _MiniMapViewportOverlayPainter extends CustomPainter {
  _MiniMapViewportOverlayPainter({required this.indicatorRect});

  final Rect indicatorRect;

  @override
  void paint(Canvas canvas, Size size) {
    if (indicatorRect.isEmpty) {
      return;
    }
    final fill = Paint()
      ..color = Colors.black.withValues(alpha: 0.26)
      ..style = PaintingStyle.fill;
    canvas.drawRect(indicatorRect, fill);
  }

  @override
  bool shouldRepaint(covariant _MiniMapViewportOverlayPainter oldDelegate) {
    return oldDelegate.indicatorRect != indicatorRect;
  }
}
