import 'package:flutter/material.dart';

import '../core/storage/shutdown_coordinator.dart';

/// Blocks account edits until the server's storage protocol is established.
///
/// A previously verified user cannot unlock another account's editor.
/// No account editor mounts before its v2 writer is ready.
class AccountProtocolEditorGate extends StatefulWidget {
  const AccountProtocolEditorGate({
    required this.isSignedIn,
    required this.userId,
    required this.v2ReadyUser,
    this.blockingReason,
    required this.onRetry,
    required this.onLogOut,
    this.onLogOutOffline,
    required this.child,
    super.key,
  });

  final bool isSignedIn;
  final String? userId;
  final String? v2ReadyUser;
  final String? blockingReason;
  final Future<void> Function() onRetry;
  final Future<void> Function() onLogOut;
  final Future<void> Function()? onLogOutOffline;
  final Widget child;

  bool get canEdit =>
      !isSignedIn ||
      (userId != null && userId!.isNotEmpty && v2ReadyUser == userId);

  @override
  State<AccountProtocolEditorGate> createState() =>
      _AccountProtocolEditorGateState();
}

class _AccountProtocolEditorGateState extends State<AccountProtocolEditorGate> {
  bool _retrying = false;
  bool _signingOut = false;
  bool _canSignOutOffline = false;
  String? _error;

  Future<void> _attempt({
    required bool loggingOut,
    bool offline = false,
  }) async {
    if (loggingOut ? _signingOut : _retrying) {
      return;
    }
    setState(() {
      if (loggingOut) {
        _signingOut = true;
      } else {
        _retrying = true;
      }
      _error = null;
      _canSignOutOffline = false;
    });
    try {
      if (loggingOut) {
        if (offline) {
          await widget.onLogOutOffline?.call();
        } else {
          await widget.onLogOut();
        }
      } else {
        await widget.onRetry();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '${loggingOut ? 'Log out' : 'Retry'} failed: $error';
          _canSignOutOffline =
              loggingOut && error is ShutdownInterrupted && error.localSafe;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          if (loggingOut) {
            _signingOut = false;
          } else {
            _retrying = false;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.canEdit) {
      return widget.child;
    }
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  widget.blockingReason ??
                      'Checking the account sync protocol. Editing is paused '
                          'until the account version is verified.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: _retrying
                          ? null
                          : () => _attempt(loggingOut: false),
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: _signingOut
                          ? null
                          : () => _attempt(loggingOut: true),
                      child: const Text('Log out'),
                    ),
                    if (_canSignOutOffline && widget.onLogOutOffline != null)
                      TextButton(
                        onPressed: _signingOut
                            ? null
                            : () => _attempt(loggingOut: true, offline: true),
                        child: const Text('Log out offline'),
                      ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
