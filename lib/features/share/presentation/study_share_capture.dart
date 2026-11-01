import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/sync/study_share_service.dart';

/// Shows session controls without taking screenshots of the editable canvas.
///
/// The shared document itself is synchronized through the authenticated
/// session API; PNG snapshots are not authoritative document state.
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
  Timer? _expiryTicker;
  bool _extending = false;
  String? _extensionError;

  @override
  void initState() {
    super.initState();
    _expiryTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {});
      }
    });
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
    _expiryTicker?.cancel();
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
        widget.child,
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
