import 'dart:async';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../../data/sync/study_share_service.dart';
import '../../editor/state/editor_controller.dart';

/// Captures only the open editor, never the account or library sidebar.
class StudyShareCapture extends StatefulWidget {
  const StudyShareCapture({
    required this.share,
    required this.service,
    required this.child,
    required this.onExtended,
    super.key,
  });

  final ActiveStudyShare share;
  final StudyShareService service;
  final Widget child;
  final ValueChanged<ActiveStudyShare> onExtended;

  @override
  State<StudyShareCapture> createState() => _StudyShareCaptureState();
}

class _StudyShareCaptureState extends State<StudyShareCapture> {
  final GlobalKey _captureKey = GlobalKey();
  EditorController? _editor;
  Timer? _timer;
  Timer? _expiryTicker;
  bool _extending = false;
  String? _extensionError;
  bool _dirty = true;
  bool _busy = false;
  String? _previousDigest;

  @override
  void initState() {
    super.initState();
    _expiryTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final editor = context.read<EditorController>();
    if (identical(_editor, editor)) {
      return;
    }
    _editor?.removeListener(_schedule);
    _editor = editor..addListener(_schedule);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant StudyShareCapture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.share.id != oldWidget.share.id) {
      _previousDigest = null;
      _schedule();
    }
  }

  void _schedule() {
    _dirty = true;
    if (_timer != null || _busy) {
      return;
    }
    _timer = Timer(const Duration(milliseconds: 1500), _capture);
  }

  Future<void> _capture() async {
    _timer = null;
    if (!mounted || !_dirty || _busy) {
      return;
    }
    _dirty = false;
    _busy = true;
    try {
      final boundary =
          _captureKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null || !boundary.hasSize || boundary.debugNeedsPaint) {
        _dirty = true;
        return;
      }
      final scale = (1440 / boundary.size.longestSide)
          .clamp(0.25, 1.0)
          .toDouble();
      final picture = await boundary.toImage(pixelRatio: scale);
      try {
        final encoded = await picture.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (!mounted || encoded == null) {
          return;
        }
        final png = encoded.buffer.asUint8List();
        if (png.length > 2 * 1024 * 1024) {
          return;
        }
        final digest = sha256.convert(png).toString();
        if (_previousDigest == digest) {
          return;
        }
        await widget.service.publish(widget.share, png);
        _previousDigest = digest;
      } finally {
        picture.dispose();
      }
    } catch (error) {
      debugPrint('Study share frame could not be published: $error');
    } finally {
      _busy = false;
      if (mounted && _dirty) {
        _schedule();
      }
    }
  }

  Future<void> _extendSession() async {
    if (_extending) {
      return;
    }
    setState(() {
      _extending = true;
      _extensionError = null;
    });
    try {
      final updated = await widget.service.extend(widget.share);
      if (mounted) {
        widget.onExtended(updated);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _extensionError = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _extending = false);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _expiryTicker?.cancel();
    _editor?.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.share.expiresAt.difference(DateTime.now().toUtc());
    final warning =
        remaining <= const Duration(minutes: 5) && remaining > Duration.zero;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _captureKey, child: widget.child),
        if (warning)
          Positioned(
            bottom: 14,
            right: 14,
            child: Material(
              key: const ValueKey('study-share-expiry-warning'),
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              elevation: 2,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Study session expires soon'),
                    if (_extensionError != null)
                      Text(
                        _extensionError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    TextButton(
                      onPressed: _extending ? null : _extendSession,
                      child: const Text('Extend session'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
