import 'package:flutter/material.dart';

/// Gives dialog footer labels the same foreground as standard app text.
List<Widget> appDialogActions(BuildContext context, List<Widget> actions) {
  final color = Theme.of(context).colorScheme.onSurface;
  final buttonTheme = TextButtonThemeData(
    style: TextButton.styleFrom(foregroundColor: color),
  );

  return [
    for (final action in actions)
      TextButtonTheme(data: buttonTheme, child: action),
  ];
}
