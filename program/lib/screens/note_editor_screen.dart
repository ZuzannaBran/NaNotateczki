import 'package:flutter/material.dart';

import '../constants.dart';
import '../state/note_editor_controller.dart';
import '../widgets/drawing_canvas.dart';
import '../widgets/editor_toolbar.dart';
import '../widgets/page_strip.dart';

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key});

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final NoteEditorController controller;
  final GlobalKey repaintBoundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    controller = NoteEditorController();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: paperColor,
      appBar: AppBar(
        title: const Text('Notatek Sketch'),
        backgroundColor: toolbarColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          EditorToolbar(
            controller: controller,
            onExportPng: () => _showPlaceholder(context, 'PNG export'),
            onExportPdf: () => _showPlaceholder(context, 'PDF export'),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: paperColor,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 12,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: DrawingCanvas(
                  controller: controller,
                  repaintBoundaryKey: repaintBoundaryKey,
                ),
              ),
            ),
          ),
          PageStrip(controller: controller),
        ],
      ),
    );
  }

  void _showPlaceholder(BuildContext context, String label) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label is not implemented yet.')));
  }
}
