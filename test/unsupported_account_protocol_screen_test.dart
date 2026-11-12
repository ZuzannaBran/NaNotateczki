import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/app/unsupported_account_protocol_screen.dart';
import 'package:program/core/storage/shutdown_coordinator.dart';

void main() {
  testWidgets('blocks editing on v2 and provides logout', (tester) async {
    var logoutCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UnsupportedAccountProtocolScreen(
          onLogOut: () async {
            logoutCalls++;
          },
        ),
      ),
    );

    expect(find.textContaining('sync v2'), findsOneWidget);
    expect(find.textContaining('Editing is disabled'), findsOneWidget);
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(logoutCalls, 1);
  });

  testWidgets('can preserve local changes when v2 sync fails', (tester) async {
    var offline = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UnsupportedAccountProtocolScreen(
          onLogOut: () async => throw const ShutdownInterrupted(
            ShutdownPhase.verifyBackup,
            true,
            'no internet',
          ),
          onLogOutOffline: () async {
            offline++;
          },
        ),
      ),
    );
    await tester.tap(find.text('Log out'));
    await tester.pump();
    expect(find.text('Log out offline'), findsOneWidget);
    await tester.tap(find.text('Log out offline'));
    await tester.pump();
    expect(offline, 1);
  });

  testWidgets('shows logout failure and permits a retry', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UnsupportedAccountProtocolScreen(
          onLogOut: () async {
            attempts++;
            if (attempts == 1) {
              throw StateError('keyring locked');
            }
          },
        ),
      ),
    );

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Log out failed'), findsOneWidget);
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.textContaining('Log out failed'), findsNothing);
  });
}
