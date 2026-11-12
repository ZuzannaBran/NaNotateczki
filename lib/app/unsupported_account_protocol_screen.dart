import 'package:flutter/material.dart';

import '../core/storage/shutdown_coordinator.dart';

/// Prevents editing when this client cannot save the account protocol.
class UnsupportedAccountProtocolScreen extends StatefulWidget {
  const UnsupportedAccountProtocolScreen({
    required this.onLogOut,
    this.onLogOutOffline,
    super.key,
  });

  final Future<void> Function() onLogOut;
  final Future<void> Function()? onLogOutOffline;

  @override
  State<UnsupportedAccountProtocolScreen> createState() =>
      _UnsupportedAccountProtocolScreenState();
}

class _UnsupportedAccountProtocolScreenState
    extends State<UnsupportedAccountProtocolScreen> {
  bool _signingOut = false;
  bool _canSignOutOffline = false;
  String? _error;

  Future<void> _logOut({bool offline = false}) async {
    setState(() {
      _signingOut = true;
      _error = null;
      _canSignOutOffline = false;
    });
    try {
      if (offline) {
        await widget.onLogOutOffline?.call();
      } else {
        await widget.onLogOut();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Log out failed: $error';
          _canSignOutOffline = error is ShutdownInterrupted && error.localSafe;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _signingOut = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'This account uses sync v2. This version of the editor '
                  'cannot save changes to it. Editing is disabled to prevent '
                  'unsynced changes. Your local files are preserved.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                ],
                ElevatedButton(
                  onPressed: _signingOut ? null : () => _logOut(),
                  child: const Text('Log out'),
                ),
                if (_canSignOutOffline && widget.onLogOutOffline != null)
                  TextButton(
                    onPressed: _signingOut
                        ? null
                        : () => _logOut(offline: true),
                    child: const Text('Log out offline'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
