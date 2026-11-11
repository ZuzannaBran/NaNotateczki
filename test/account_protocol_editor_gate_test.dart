import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/app/account_protocol_editor_gate.dart';

void main() {
  Widget app({
    required bool signedIn,
    String? userId,
    String? legacyReadyUser,
    String? v2ReadyUser,
    String? blockingReason,
    Future<void> Function()? onRetry,
    Future<void> Function()? onLogOut,
  }) => MaterialApp(
    home: AccountProtocolEditorGate(
      isSignedIn: signedIn,
      userId: userId,
      legacyReadyUser: legacyReadyUser,
      v2ReadyUser: v2ReadyUser,
      blockingReason: blockingReason,
      onRetry: onRetry ?? () async {},
      onLogOut: onLogOut ?? () async {},
      child: const Scaffold(body: Text('Editor content')),
    ),
  );

  testWidgets('account editor cannot mount while protocol is unknown', (
    tester,
  ) async {
    await tester.pumpWidget(app(signedIn: true, userId: 'account-a'));
    expect(find.text('Editor content'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(
      app(signedIn: true, userId: 'account-a', legacyReadyUser: 'account-a'),
    );
    expect(find.text('Editor content'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpWidget(app(signedIn: true, userId: 'account-a'));
    expect(find.text('Editor content'), findsNothing);
  });

  testWidgets('v2 unlocks only its own account after runtime bootstrap', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        signedIn: true,
        userId: 'account-b',
        legacyReadyUser: 'account-a',
        v2ReadyUser: 'account-a',
      ),
    );
    expect(find.text('Editor content'), findsNothing);

    await tester.pumpWidget(
      app(
        signedIn: true,
        userId: 'account-b',
        legacyReadyUser: 'account-a',
        v2ReadyUser: 'account-b',
      ),
    );
    expect(find.text('Editor content'), findsOneWidget);

    await tester.pumpWidget(
      app(signedIn: true, userId: 'account-c', v2ReadyUser: 'account-b'),
    );
    expect(find.text('Editor content'), findsNothing);
  });

  testWidgets('local mode stays usable without an account protocol', (
    tester,
  ) async {
    await tester.pumpWidget(app(signedIn: false));
    expect(find.text('Editor content'), findsOneWidget);
  });
  testWidgets('pending Local import explains why editor remains blocked', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        signedIn: true,
        userId: 'account-a',
        blockingReason: 'Local import paused: missing verified asset.',
      ),
    );
    expect(find.textContaining('Local import paused'), findsOneWidget);
    expect(find.text('Editor content'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('blocked account offers retry and logout', (tester) async {
    var retries = 0;
    var logouts = 0;
    await tester.pumpWidget(
      app(
        signedIn: true,
        userId: 'account-a',
        onRetry: () async {
          retries++;
        },
        onLogOut: () async {
          logouts++;
        },
      ),
    );
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);
    await tester.tap(find.text('Log out'));
    await tester.pump();
    expect(logouts, 1);
    expect(find.text('Editor content'), findsNothing);
  });

  testWidgets('logout failure is shown without unlocking editing', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        signedIn: true,
        userId: 'account-a',
        onLogOut: () async => throw StateError('offline keyring'),
      ),
    );
    await tester.tap(find.text('Log out'));
    await tester.pump();
    expect(find.textContaining('Log out failed'), findsOneWidget);
    expect(find.text('Editor content'), findsNothing);
  });
}
