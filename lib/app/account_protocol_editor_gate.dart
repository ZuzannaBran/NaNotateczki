import 'package:flutter/material.dart';

/// Blocks account edits until the server's storage protocol is established.
///
/// A previously verified user cannot unlock another account's editor.
/// Failure to check the protocol keeps legacy snapshot writers unavailable.
class AccountProtocolEditorGate extends StatelessWidget {
  const AccountProtocolEditorGate({
    required this.isSignedIn,
    required this.userId,
    required this.legacyReadyUser,
    required this.v2ReadyUser,
    required this.child,
    super.key,
  });

  final bool isSignedIn;
  final String? userId;
  final String? legacyReadyUser;
  final String? v2ReadyUser;
  final Widget child;

  bool get canEdit =>
      !isSignedIn ||
      (userId != null &&
          userId!.isNotEmpty &&
          (legacyReadyUser == userId || v2ReadyUser == userId));

  @override
  Widget build(BuildContext context) {
    if (!canEdit) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return child;
  }
}
