import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/theme/app_theme.dart';
import 'package:program/core/widgets/app_dialog_actions.dart';

void main() {
  testWidgets('dialog footer text matches regular text in both modes', (
    tester,
  ) async {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Rename item'),
                    content: TextButton(
                      onPressed: () {},
                      child: const Text('Content action'),
                    ),
                    actions: appDialogActions(dialogContext, [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Rename'),
                      ),
                    ]),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      for (final label in ['Cancel', 'Rename']) {
        final action = find.widgetWithText(TextButton, label);
        final actionContext = tester.element(action);
        final buttonColor = TextButtonTheme.of(actionContext)
            .style
            ?.foregroundColor
            ?.resolve(<WidgetState>{});
        expect(buttonColor, theme.colorScheme.onSurface);
        expect(
          DefaultTextStyle.of(tester.element(find.text(label))).style.color,
          theme.colorScheme.onSurface,
        );
      }

      final contentContext = tester.element(
        find.widgetWithText(TextButton, 'Content action'),
      );
      expect(TextButtonTheme.of(contentContext).style, isNull);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Rename item'), findsNothing);
    }
  });
}
