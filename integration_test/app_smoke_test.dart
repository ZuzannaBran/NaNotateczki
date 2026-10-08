import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:program/app/notes_app.dart';
import 'package:program/features/library/presentation/library_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real platform bootstrap opens the library', (tester) async {
    await tester.pumpWidget(const NotesApp());
    expect(find.byType(MaterialApp), findsOneWidget);

    for (var attempt = 0; attempt < 60; attempt++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(LibraryScreen).evaluate().isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 75)),
      );
    }

    expect(
      find.byType(LibraryScreen),
      findsOneWidget,
      reason: 'The actual platform storage/plugin initialization must '
          'reach the library, not just display a loading spinner.',
    );
  });
}
