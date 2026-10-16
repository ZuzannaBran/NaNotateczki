import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/theme/app_theme.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';

void main() {
  testWidgets('lasso actions use compact, theme-matched controls', (
    tester,
  ) async {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      var copied = 0;
      var deleted = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: LassoSelectionActionBar(
                onCopy: () => copied++,
                onDelete: () => deleted++,
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      final copy = find.byTooltip('Copy selection');
      final delete = find.byTooltip('Delete selection');
      expect(copy, findsOneWidget);
      expect(delete, findsOneWidget);

      final barSize = tester.getSize(find.byType(LassoSelectionActionBar));
      expect(barSize.width, lessThan(100));
      expect(barSize.height, lessThan(48));

      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(LassoSelectionActionBar),
          matching: find.byType(Material),
        ),
      );
      expect(material.color, theme.colorScheme.surfaceContainerLowest);

      final expectedIconColor = theme.colorScheme.onSurface.withValues(
        alpha: 0.72,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.content_copy_outlined)).color,
        expectedIconColor,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.delete_outline)).color,
        expectedIconColor,
      );

      await tester.tap(copy);
      await tester.pump();
      await tester.tap(delete);
      await tester.pump();
      expect(copied, 1);
      expect(deleted, 1);
    }
  });
}
