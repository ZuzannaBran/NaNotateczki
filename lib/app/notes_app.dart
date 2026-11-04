import 'package:flutter/material.dart';

import 'app_scope.dart';

class NotesApp extends StatefulWidget {
  const NotesApp({super.key});

  @override
  State<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends State<NotesApp> {
  int _generation = 0;

  void _rebuildForNamespace() {
    if (mounted) {
      setState(() => _generation++);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      key: ValueKey(_generation),
      onNamespaceSwitch: _rebuildForNamespace,
    );
  }
}
