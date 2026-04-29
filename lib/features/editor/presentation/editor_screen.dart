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
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
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
  static const double _a4HeightRatio = 297 / 210;
  static const double _pageGap = 26;
  static const double _leftMargin = 24;
  static const double _rightMargin = 56;
  static const double _topBottomPadding = 22;
  static const double _minPageScaleFactor = 1.0;
  static const double _maxPageScaleFloor = 1.8;
  static const double _postFitZoomFactor = 2.0;
  static const double _touchPanSensitivity = 0.55;
  static const double _trackpadPanSensitivity = 0.6;
  static const double _scrollPanSensitivity = 0.38;

  final ScrollController _scrollController = ScrollController();
  bool _isAutoAddingPage = false;
  bool _wasScrollingDown = false;
  DateTime _lastAutoAddAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _pageExtent = 0;
  bool _isViewportNavigating = false;
  bool _panZoomSessionActive = false;
  final Map<int, Offset> _activePointers = <int, Offset>{};
  Offset _touchLastFocal = Offset.zero;
  double _touchLastDistance = 1.0;
  Offset _panZoomLastPan = Offset.zero;
  double _panZoomLastScale = 1.0;
  Offset _panZoomLastLocalPosition = Offset.zero;
  double _pageScale = 1.0;
  Offset _pagePan = Offset.zero;
  double _pageMinScale = 1.0;
  double _pageMaxScale = 1.0;

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

    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      _wasScrollingDown = delta > 0;
      if (_pageScale > 1.001 || _isViewportNavigating) {
        if (delta > 0) {
          _tryAutoAddPage(notification.metrics, controller);
        }
      }
      return false;
    }

    if (notification is ScrollEndNotification ||
        (notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle)) {
      _syncCurrentPageToViewport(controller);
      if (_wasScrollingDown) {
        _tryAutoAddPage(notification.metrics, controller);
      }
      _wasScrollingDown = false;
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

  void _tryAutoAddPage(ScrollMetrics metrics, EditorController controller) {
    if (_isAutoAddingPage) {
      return;
    }
    if (metrics.extentAfter > 80) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastAutoAddAt) < const Duration(milliseconds: 450)) {
      return;
    }

    _isAutoAddingPage = true;
    _lastAutoAddAt = now;
    final previousCount = controller.pages.length;
    controller.addPage();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scrollController.hasClients) {
        _isAutoAddingPage = false;
        return;
      }
      final targetOffset = (_pageExtent * previousCount).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      try {
        await _scrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } catch (_) {}
      if (mounted) {
        _isAutoAddingPage = false;
      }
    });
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

  bool _isNavigationPointerKind(PointerDeviceKind kind) {
    return kind != PointerDeviceKind.stylus &&
        kind != PointerDeviceKind.invertedStylus;
  }

  void _onPointerDown(
    PointerDownEvent event,
    Size docWorldSize,
    Size viewportSize,
  ) {
    if (!_isNavigationPointerKind(event.kind)) {
      return;
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
    if (!_isNavigationPointerKind(event.kind)) {
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

    _applyPageTransform(
      scaleDelta: scaleDelta,
      panDelta: panDelta * _touchPanSensitivity,
      focalPoint: focal,
      docWorldSize: docWorldSize,
      viewportSize: viewportSize,
    );
  }

  void _onPointerUpOrCancel(PointerEvent event) {
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
        final controller = context.read<EditorController>();
        if (overflow.dy < 0) {
          _tryAutoAddPage(position, controller);
        }
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
      minX = 0.0;
      maxX = 0.0;
    } else {
      minX = viewportSize.width - contentWidth;
      maxX = 0.0;
    }

    late final double minY;
    late final double maxY;
    if (contentHeight <= viewportSize.height) {
      minY = 0.0;
      maxY = 0.0;
    } else {
      minY = viewportSize.height - contentHeight;
      maxY = 0.0;
    }

    final clampedX = pan.dx.clamp(minX, maxX).toDouble();
    final clampedY = pan.dy.clamp(minY, maxY).toDouble();
    return Offset(clampedX, clampedY);
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

    final worldLeft =
      ((-_pagePan.dx) / safeScale).clamp(0.0, docWorldSize.width);
    final worldRight =
        ((viewportSize.width - _pagePan.dx) / safeScale)
            .clamp(0.0, docWorldSize.width);
    final worldTop =
        ((clipTop - _pagePan.dy) / safeScale).clamp(0.0, docHeight);
    final worldBottom =
        ((clipBottom - _pagePan.dy) / safeScale).clamp(0.0, docHeight);

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

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final useWideTitleInset = MediaQuery.sizeOf(context).width >= 600;

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
      body: Column(
        children: [
          EditorToolbar(controller: controller),
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
                final pageHeight = pageWidth * _a4HeightRatio;
                final pageWorldSize = Size(pageWidth, pageHeight);
                final docHeight = _documentHeight(
                  pageHeight: pageWorldSize.height,
                  pageCount: controller.pages.length,
                );
                final docWorldSize = Size(pageWorldSize.width, docHeight);
                final fitToWidthScale = (maxPageWidth / pageWidth)
                    .clamp(1.0, 4.0)
                    .toDouble();
                final clipScale = math.min(_pageScale, fitToWidthScale);
                final clipSize = Size(
                  docWorldSize.width * clipScale,
                  docWorldSize.height * clipScale,
                );
                final viewportSize = Size(
                  clipSize.width,
                  math.max(1.0, constraints.maxHeight - (_topBottomPadding * 2)),
                );
                final zoomPercent = (_pageScale * 100).round();
                final visibleDocumentRect = _visibleDocumentRect(
                  docWorldSize: docWorldSize,
                  viewportSize: viewportSize,
                );
                final minimapBoundaryVisibility =
                    _pageBoundaryVisibilityInDocument(
                      visibleDocumentRect: visibleDocumentRect,
                      pageWorldSize: pageWorldSize,
                      pageIndex: controller.currentPageIndex,
                    );
                final minimapPanelHeight = math.min(
                  pageWorldSize.height * 0.5,
                  math.max(180.0, constraints.maxHeight - 24),
                );
                _pageExtent = pageWorldSize.height + _pageGap;
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
                          physics: (_isViewportNavigating || _pageScale > 1.001)
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
                            child: SizedBox(
                              width: clipSize.width,
                              height: clipSize.height,
                              child: ClipRect(
                                child: Listener(
                                  behavior: HitTestBehavior.translucent,
                                  onPointerDown: (event) => _onPointerDown(
                                    event,
                                    docWorldSize,
                                    viewportSize,
                                  ),
                                  onPointerMove: (event) => _onPointerMove(
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
                                  onPointerPanZoomEnd: _onPointerPanZoomEnd,
                                  onPointerSignal: (event) => _onPointerSignal(
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
                                          for (var i = 0;
                                              i < controller.pages.length;
                                              i++)
                                            Positioned(
                                              left: 0,
                                              top: i * _pageExtent,
                                              width: pageWorldSize.width,
                                              height: pageWorldSize.height,
                                              child: IgnorePointer(
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    DecoratedBox(
                                                      decoration: BoxDecoration(
                                                        color: AppColors.paper,
                                                        boxShadow: const [
                                                          BoxShadow(
                                                            color:
                                                                AppColors.shadow,
                                                            blurRadius: 14,
                                                            offset:
                                                                Offset(0, 6),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    Builder(
                                                      builder: (context) {
                                                        final visibility =
                                                            _pageBoundaryVisibilityInDocument(
                                                          visibleDocumentRect:
                                                              visibleDocumentRect,
                                                          pageWorldSize:
                                                              pageWorldSize,
                                                          pageIndex: i,
                                                        );
                                                        return CustomPaint(
                                                          painter:
                                                              _PageFramePainter(
                                                            showLeft:
                                                                visibility.left,
                                                            showTop: visibility.top,
                                                            showRight:
                                                                visibility.right,
                                                            showBottom:
                                                                visibility.bottom,
                                                            highlightColor:
                                                                Theme.of(context)
                                                                    .colorScheme
                                                                    .primary
                                                                    .withValues(
                                                                      alpha: 0.75,
                                                                    ),
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          DocumentDrawingCanvas(
                                            allowMultiTouch: false,
                                            interactionEnabled:
                                                !_isViewportNavigating,
                                            worldOrigin: Offset.zero,
                                            pages: controller.pages,
                                            pageSize: pageWorldSize,
                                            pageGap: _pageGap,
                                          ),
                                          DocumentPageOverlay(
                                            controller: controller,
                                            interactionEnabled:
                                                !_isViewportNavigating,
                                            worldOrigin: Offset.zero,
                                            pages: controller.pages,
                                            pageSize: pageWorldSize,
                                            pageGap: _pageGap,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
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
                          boundaryVisibility: minimapBoundaryVisibility,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

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
    required this.boundaryVisibility,
  });

  final List<NotePage> pages;
  final int currentPageIndex;
  final Size pageWorldSize;
  final double pageGap;
  final double panelHeight;
  final Rect visibleDocumentRect;
  final _BoundaryVisibility boundaryVisibility;

  @override
  State<_ProjectMiniMapOverlay> createState() => _ProjectMiniMapOverlayState();
}

class _ProjectMiniMapOverlayState extends State<_ProjectMiniMapOverlay> {
  final ScrollController _minimapScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncMinimapToViewport();
    });
  }

  @override
  void didUpdateWidget(covariant _ProjectMiniMapOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_minimapScrollController.hasClients) {
        return;
      }
      final max = _minimapScrollController.position.maxScrollExtent;
      if (_minimapScrollController.offset > max) {
        _minimapScrollController.jumpTo(max);
      }
      _syncMinimapToViewport();
    });
  }

  void _syncMinimapToViewport() {
    if (!mounted || !_minimapScrollController.hasClients) {
      return;
    }
    const minimapWidth = 84.0;
    final worldWidth = math.max(1.0, widget.pageWorldSize.width);
    final mapScale = minimapWidth / worldWidth;

    final indicatorTop = widget.visibleDocumentRect.top * mapScale;
    final indicatorBottom = widget.visibleDocumentRect.bottom * mapScale;
    final viewTop = _minimapScrollController.offset;
    final viewBottom = viewTop + widget.panelHeight;
    final margin = widget.panelHeight * 0.18;

    double? target;
    if (indicatorTop < viewTop + margin) {
      target = indicatorTop - margin;
    } else if (indicatorBottom > viewBottom - margin) {
      target = indicatorBottom - widget.panelHeight + margin;
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

  @override
  void dispose() {
    _minimapScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const minimapWidth = 84.0;
    final worldWidth = math.max(1.0, widget.pageWorldSize.width);
    final worldHeight = math.max(
      1.0,
      (widget.pages.length * widget.pageWorldSize.height) +
          (math.max(0, widget.pages.length - 1) * widget.pageGap),
    );
    final mapScale = minimapWidth / worldWidth;
    final contentHeight = math.max(widget.panelHeight, worldHeight * mapScale);
    final canScroll = contentHeight > widget.panelHeight + 0.5;
    final indicatorRectInContent = Rect.fromLTWH(
      widget.visibleDocumentRect.left * mapScale,
      widget.visibleDocumentRect.top * mapScale,
      widget.visibleDocumentRect.width * mapScale,
      math.max(3.0, widget.visibleDocumentRect.height * mapScale),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.toolbar.withValues(alpha: 0.9),
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
        padding: const EdgeInsets.all(6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: minimapWidth,
            height: widget.panelHeight,
            child: Stack(
              children: [
                SingleChildScrollView(
                  controller: _minimapScrollController,
                  physics: canScroll
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size(minimapWidth, contentHeight),
                      painter: _ProjectMiniMapPainter(
                        pages: widget.pages,
                        currentPageIndex: widget.currentPageIndex,
                        pageWorldSize: widget.pageWorldSize,
                        pageGap: widget.pageGap,
                        mapScale: mapScale,
                        boundaryVisibility: widget.boundaryVisibility,
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
                              Rect.fromLTWH(
                                0,
                                0,
                                minimapWidth,
                                widget.panelHeight,
                              ),
                            );
                        return CustomPaint(
                          painter: _MiniMapViewportOverlayPainter(
                            indicatorRect: rect,
                            boundaryVisibility: widget.boundaryVisibility,
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
    required this.boundaryVisibility,
  });

  final List<NotePage> pages;
  final int currentPageIndex;
  final Size pageWorldSize;
  final double pageGap;
  final double mapScale;
  final _BoundaryVisibility boundaryVisibility;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFFF8FAFD);
    canvas.drawRect(Offset.zero & size, background);

    final border = Paint()
      ..color = const Color(0xFFCFD7E4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect((Offset.zero & size).deflate(0.5), border);

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

      if (isCurrentPage && boundaryVisibility.any) {
        final highlightPaint = Paint()
          ..color = const Color(0xFF0E8A97).withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9;
        final edgeRect = pageRect.deflate(0.3);
        if (boundaryVisibility.left) {
          canvas.drawLine(
            edgeRect.topLeft,
            edgeRect.bottomLeft,
            highlightPaint,
          );
        }
        if (boundaryVisibility.top) {
          canvas.drawLine(edgeRect.topLeft, edgeRect.topRight, highlightPaint);
        }
        if (boundaryVisibility.right) {
          canvas.drawLine(
            edgeRect.topRight,
            edgeRect.bottomRight,
            highlightPaint,
          );
        }
        if (boundaryVisibility.bottom) {
          canvas.drawLine(
            edgeRect.bottomLeft,
            edgeRect.bottomRight,
            highlightPaint,
          );
        }
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
        final topLeft = toMap(block.position);
        final rect = Rect.fromLTWH(
          topLeft.dx,
          topLeft.dy,
          block.width * scaleX,
          block.height * scaleY,
        );
        final rounded = RRect.fromRectAndRadius(
          rect,
          const Radius.circular(1.5),
        );
        canvas.drawRRect(rounded, imageFill);
        canvas.drawRRect(rounded, imageBorder);
      }

      final textPaint = Paint()..color = const Color(0xFF95A2B4);
      for (final block in page.textBlocks) {
        final topLeft = toMap(block.position + const Offset(0, 2));
        final lineWidth = (block.width * scaleX * 0.8)
            .clamp(6.0, size.width * 0.84)
            .toDouble();
        final lineHeight = math.max(1.0, block.fontSize * scaleY * 0.18);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(topLeft.dx, topLeft.dy, lineWidth, lineHeight),
          const Radius.circular(0.8),
        );
        canvas.drawRRect(rect, textPaint);
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
        oldDelegate.boundaryVisibility != boundaryVisibility;
  }
}

class _MiniMapViewportOverlayPainter extends CustomPainter {
  _MiniMapViewportOverlayPainter({
    required this.indicatorRect,
    required this.boundaryVisibility,
  });

  final Rect indicatorRect;
  final _BoundaryVisibility boundaryVisibility;

  @override
  void paint(Canvas canvas, Size size) {
    if (indicatorRect.isEmpty) {
      return;
    }
    final fill = Paint()
      ..color = Colors.black.withValues(alpha: 0.26)
      ..style = PaintingStyle.fill;
    canvas.drawRect(indicatorRect, fill);
    if (boundaryVisibility.any) {
      final border = Paint()
        ..color = const Color(0xFF0E8A97).withValues(alpha: 0.92)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9;
      if (boundaryVisibility.left) {
        canvas.drawLine(
          indicatorRect.topLeft,
          indicatorRect.bottomLeft,
          border,
        );
      }
      if (boundaryVisibility.top) {
        canvas.drawLine(indicatorRect.topLeft, indicatorRect.topRight, border);
      }
      if (boundaryVisibility.right) {
        canvas.drawLine(
          indicatorRect.topRight,
          indicatorRect.bottomRight,
          border,
        );
      }
      if (boundaryVisibility.bottom) {
        canvas.drawLine(
          indicatorRect.bottomLeft,
          indicatorRect.bottomRight,
          border,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MiniMapViewportOverlayPainter oldDelegate) {
    return oldDelegate.indicatorRect != indicatorRect ||
        oldDelegate.boundaryVisibility != boundaryVisibility;
  }
}
