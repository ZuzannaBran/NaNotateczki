import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/drawing_tool.dart';
import '../state/note_editor_controller.dart';

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    required this.controller,
    required this.onExportPng,
    required this.onExportPdf,
    super.key,
  });

  final NoteEditorController controller;
  final VoidCallback onExportPng;
  final VoidCallback onExportPdf;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: toolbarColor,
          child: Row(
            children: [
              _toolButton(
                icon: Icons.edit,
                selected: controller.tool == DrawingTool.pen,
                onPressed: () => controller.setTool(DrawingTool.pen),
                tooltip: 'Pen',
              ),
              _toolButton(
                icon: Icons.auto_fix_off,
                selected: controller.tool == DrawingTool.eraser,
                onPressed: () => controller.setTool(DrawingTool.eraser),
                tooltip: 'Eraser',
              ),
              const SizedBox(width: 16),
              for (final color in inkPalette)
                _colorDot(
                  color: color,
                  selected:
                      controller.inkColor == color &&
                      controller.tool == DrawingTool.pen,
                  onTap: () => controller.setColor(color),
                ),
              const SizedBox(width: 16),
              SizedBox(
                width: 140,
                child: Slider(
                  value: controller.strokeWidth,
                  min: minStrokeWidth,
                  max: maxStrokeWidth,
                  onChanged: controller.setStrokeWidth,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.undo),
                onPressed: controller.canUndo ? controller.undo : null,
                tooltip: 'Undo',
              ),
              IconButton(
                icon: const Icon(Icons.redo),
                onPressed: controller.canRedo ? controller.redo : null,
                tooltip: 'Redo',
              ),
              IconButton(
                icon: const Icon(Icons.picture_as_pdf),
                onPressed: onExportPdf,
                tooltip: 'Export PDF',
              ),
              IconButton(
                icon: const Icon(Icons.image_outlined),
                onPressed: onExportPng,
                tooltip: 'Export PNG',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _toolButton({
    required IconData icon,
    required bool selected,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return IconButton(
      icon: Icon(icon),
      onPressed: onPressed,
      tooltip: tooltip,
      color: selected ? inkBlack : null,
    );
  }

  Widget _colorDot({
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected ? inkBlack : Colors.transparent,
            width: 2,
          ),
        ),
      ),
    );
  }
}
