import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/app_dialog_actions.dart';
import '../../../data/sync/study_share_service.dart';
import '../../notebook/domain/notebook.dart';

Future<void> showStudyShareDialog(
  BuildContext context, {
  required Notebook document,
  required StudyShareService service,
  required ActiveStudyShare? active,
  required ValueChanged<ActiveStudyShare> onChanged,
  required VoidCallback onEnded,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _StudyShareDialog(
      document: document,
      service: service,
      active: active,
      onChanged: onChanged,
      onEnded: onEnded,
    ),
  );
}

class _StudyShareDialog extends StatefulWidget {
  const _StudyShareDialog({
    required this.document,
    required this.service,
    required this.active,
    required this.onChanged,
    required this.onEnded,
  });

  final Notebook document;
  final StudyShareService service;
  final ActiveStudyShare? active;
  final ValueChanged<ActiveStudyShare> onChanged;
  final VoidCallback onEnded;

  @override
  State<_StudyShareDialog> createState() => _StudyShareDialogState();
}

class _StudyShareDialogState extends State<_StudyShareDialog> {
  final TextEditingController _password = TextEditingController();
  Timer? _clock;
  ActiveStudyShare? _active;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _active = widget.active;
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _active != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _password.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_password.text.length < 8) {
      setState(() => _error = 'Use a session password of at least 8 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.service.create(
        documentUid: widget.document.uid,
        title: widget.document.title,
        password: _password.text,
      );
      if (!mounted) {
        return;
      }
      setState(() => _active = result);
      widget.onChanged(result);
      await Clipboard.setData(ClipboardData(text: result.link));
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _extend() async {
    final active = _active;
    if (active == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.service.extend(active);
      if (!mounted) {
        return;
      }
      setState(() => _active = result);
      widget.onChanged(result);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _end() async {
    final active = _active;
    if (active == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.end(active);
      if (!mounted) {
        return;
      }
      setState(() => _active = null);
      widget.onEnded();
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final remaining = active?.expiresAt.difference(DateTime.now().toUtc());
    final aboutToExpire =
        remaining != null && remaining <= const Duration(minutes: 5);
    final canExtend =
        remaining != null &&
        remaining > Duration.zero &&
        remaining <= const Duration(minutes: 15);
    return AlertDialog(
      title: const Text('Share study session'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.document.title),
            const SizedBox(height: 16),
            if (active == null) ...[
              const Text('Guests can watch the canvas live. Only you can edit.'),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: !_showPassword,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Session password',
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    icon: Icon(
                      _showPassword ? Icons.visibility_off_outlined :
                          Icons.visibility_outlined,
                    ),
                    onPressed: () {
                      setState(() => _showPassword = !_showPassword);
                    },
                  ),
                ),
              ),
            ] else ...[
              const Text('Invitation link'),
              const SizedBox(height: 8),
              SelectableText(active.link),
              const SizedBox(height: 12),
              Text(
                aboutToExpire
                    ? 'This session is about to expire.'
                    : 'Expires at ' + TimeOfDay.fromDateTime(
                        active.expiresAt.toLocal(),
                      ).format(context),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              if (aboutToExpire)
                const Text('Extend it to keep everyone connected.'),
              const SizedBox(height: 8),
              const Text(
                'Ending sharing does not remove the project from your account.',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              )),
            ],
          ],
        ),
      ),
      actions: appDialogActions(context, [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (active != null) ...[
          TextButton(
            onPressed: _busy
                ? null
                : () => Clipboard.setData(ClipboardData(text: active.link)),
            child: const Text('Copy link'),
          ),
          if (canExtend)
            TextButton(
              onPressed: _busy ? null : _extend,
              child: const Text('Extend session'),
            ),
          TextButton(
            onPressed: _busy ? null : _end,
            child: const Text('End session'),
          ),
        ] else
          TextButton(
            onPressed: _busy ? null : _create,
            child: const Text('Create link'),
          ),
      ]),
    );
  }
}
