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
    super.key,
  });

  final ActiveStudyShare share;
  final StudyShareService service;
  final Widget child;

  @override
  State<StudyShareCapture> createState() => _StudyShareCaptureState();
}

class _StudyShareCaptureState extends State<StudyShareCapture> {
  final GlobalKey _captureKey = GlobalKey();
  EditorController? _editor;
  Timer? _timer;
  bool _dirty = true;
  bool _busy = false;
  String? _previousDigest;

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
      final scale =
          (1440 / boundary.size.longestSide).clamp(0.25, 1.0).toDouble();
      final picture = await boundary.toImage(pixelRatio: scale);
      try {
        final encoded = await picture.toByteData(format: ui.ImageByteFormat.png);
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

  @override
  void dispose() {
    _timer?.cancel();
    _editor?.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(key: _captureKey, child: widget.child);
  }
}
