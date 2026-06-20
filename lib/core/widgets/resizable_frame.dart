import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

enum ResizeDirection {
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
}

class ResizableFrame extends StatefulWidget {
  const ResizableFrame({
    required this.child,
    this.isSelected = false,
    this.onResizeStart,
    this.onResizeUpdate,
    this.onResizeEnd,
    this.handleSize = 8.0,
    this.handleHitSize = 112.0,
    super.key,
  });

  final Widget child;
  final bool isSelected;
  final void Function(ResizeDirection direction)? onResizeStart;
  final void Function(ResizeDirection direction, Offset delta)? onResizeUpdate;
  final void Function(ResizeDirection direction)? onResizeEnd;
  final double handleSize;
  final double handleHitSize;

  @override
  State<ResizableFrame> createState() => _ResizableFrameState();
}

class _ResizableFrameState extends State<ResizableFrame> {
  Offset? _lastResizeGlobalPosition;
  ResizeDirection? _activeHandle;
  bool _resizeEndScheduled = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.isSelected) {
      return widget.child;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned.fill(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildHandle(
                alignment: Alignment.topLeft,
                direction: ResizeDirection.topLeft,
                cursor: SystemMouseCursors.resizeUpLeftDownRight,
              ),
              _buildHandle(
                alignment: Alignment.topCenter,
                direction: ResizeDirection.topCenter,
                cursor: SystemMouseCursors.resizeUpDown,
              ),
              _buildHandle(
                alignment: Alignment.topRight,
                direction: ResizeDirection.topRight,
                cursor: SystemMouseCursors.resizeUpRightDownLeft,
              ),
              _buildHandle(
                alignment: Alignment.centerLeft,
                direction: ResizeDirection.centerLeft,
                cursor: SystemMouseCursors.resizeLeftRight,
              ),
              _buildHandle(
                alignment: Alignment.centerRight,
                direction: ResizeDirection.centerRight,
                cursor: SystemMouseCursors.resizeLeftRight,
              ),
              _buildHandle(
                alignment: Alignment.bottomLeft,
                direction: ResizeDirection.bottomLeft,
                cursor: SystemMouseCursors.resizeUpRightDownLeft,
              ),
              _buildHandle(
                alignment: Alignment.bottomCenter,
                direction: ResizeDirection.bottomCenter,
                cursor: SystemMouseCursors.resizeUpDown,
              ),
              _buildHandle(
                alignment: Alignment.bottomRight,
                direction: ResizeDirection.bottomRight,
                cursor: SystemMouseCursors.resizeUpLeftDownRight,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHandle({
    required Alignment alignment,
    required ResizeDirection direction,
    required MouseCursor cursor,
  }) {
    return Align(
      alignment: alignment,
      child: FractionalTranslation(
        translation: Offset(alignment.x * 0.5, alignment.y * 0.5),
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onLongPressStart: (details) {
              _resizeEndScheduled = false;
              setState(() => _activeHandle = direction);
              _lastResizeGlobalPosition = details.globalPosition;
              widget.onResizeStart?.call(direction);
            },
            onLongPressMoveUpdate: (details) {
              final previousGlobal =
                  _lastResizeGlobalPosition ?? details.globalPosition;
              final delta =
                  _globalToFrameLocal(details.globalPosition) -
                  _globalToFrameLocal(previousGlobal);
              _lastResizeGlobalPosition = details.globalPosition;
              widget.onResizeUpdate?.call(direction, delta);
            },
            onLongPressEnd: (_) => _endResize(direction),
            onLongPressUp: () => _endResize(direction),
            onLongPressCancel: () => _endResize(direction, defer: true),
            child: SizedBox(
              width: widget.handleHitSize,
              height: widget.handleHitSize,
              child: Center(
                child: AnimatedScale(
                  scale: _activeHandle == direction ? 1.8 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutBack,
                  child: Container(
                    width: widget.handleSize,
                    height: widget.handleSize,
                    decoration: BoxDecoration(
                      color: AppColors.paper,
                      border: Border.all(color: AppColors.inkBlack, width: 1.2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _endResize(ResizeDirection direction, {bool defer = false}) {
    if (_activeHandle != direction && _lastResizeGlobalPosition == null) {
      return;
    }
    if (_resizeEndScheduled) {
      return;
    }
    _resizeEndScheduled = true;
    _activeHandle = null;
    _lastResizeGlobalPosition = null;

    void notifyEnd() {
      _resizeEndScheduled = false;
      widget.onResizeEnd?.call(direction);
    }

    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() {});
        notifyEnd();
      });
      return;
    }

    setState(() {});
    notifyEnd();
  }

  Offset _globalToFrameLocal(Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) {
      return globalPosition;
    }
    return box.globalToLocal(globalPosition);
  }
}
