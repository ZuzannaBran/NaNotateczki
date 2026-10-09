import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/export/notebook_export_service.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../state/editor_controller.dart';

typedef EditorBusyRunner = Future<T> Function<T>(Future<T> Function() action);

class EditorCommands {
  const EditorCommands({
    required this.context,
    required this.controller,
    required this.insertPosition,
    required this.runBusy,
  });

  final BuildContext context;
  final EditorController controller;
  final Offset Function() insertPosition;
  final EditorBusyRunner runBusy;

  Future<void> insertFile() async {
    final message = await runBusy(
      () => controller.insertFromFilePicker(insertPosition()),
    );
    if (!context.mounted) {
      return;
    }
    if (message != null) {
      _showMessage(message);
      return;
    }
    controller.setTool(DrawingTool.edit);
  }

  Future<void> export(NotebookExportFormat format) async {
    try {
      final darkMode = Theme.of(context).brightness == Brightness.dark;
      final path = await runBusy(
        () => NotebookExportService.exportController(
          controller,
          format,
          darkMode: darkMode,
        ),
      );
      if (!context.mounted) {
        return;
      }
      _showMessage(path == null ? 'Export cancelled' : 'Exported to $path');
    } catch (error) {
      if (context.mounted) {
        _showMessage('Export failed: $error');
      }
    }
  }

  Future<void> paste() async {
    final message = await controller.pasteElementOrClipboard(insertPosition());
    if (message != null && context.mounted) {
      _showMessage(message);
    }
  }

  Future<void> copy() async {
    final message = await controller.copyActiveElementToClipboard();
    if (message != null && context.mounted) {
      _showMessage(message);
    }
  }

  Future<void> cut() async {
    final message = await controller.cutActiveElementToClipboard();
    if (message != null && context.mounted) {
      _showMessage(message);
    }
  }

  void delete() {
    controller.deleteActiveElement();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class EditorCommandShortcuts extends StatelessWidget {
  const EditorCommandShortcuts({
    required this.commands,
    required this.enabled,
    required this.child,
    super.key,
  });

  final EditorCommands commands;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _PasteFromClipboardIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            _PasteFromClipboardIntent(),
        SingleActivator(LogicalKeyboardKey.keyC, control: true):
            _CopyElementIntent(),
        SingleActivator(LogicalKeyboardKey.keyC, meta: true):
            _CopyElementIntent(),
        SingleActivator(LogicalKeyboardKey.keyX, control: true):
            _CutElementIntent(),
        SingleActivator(LogicalKeyboardKey.keyX, meta: true):
            _CutElementIntent(),
        SingleActivator(LogicalKeyboardKey.delete): _DeleteElementIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PasteFromClipboardIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              commands.paste();
              return null;
            },
          ),
          _CopyElementIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              commands.copy();
              return null;
            },
          ),
          _CutElementIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              commands.cut();
              return null;
            },
          ),
          _DeleteElementIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              commands.delete();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _PasteFromClipboardIntent extends Intent {
  const _PasteFromClipboardIntent();
}

class _CopyElementIntent extends Intent {
  const _CopyElementIntent();
}

class _CutElementIntent extends Intent {
  const _CutElementIntent();
}

class _DeleteElementIntent extends Intent {
  const _DeleteElementIntent();
}
