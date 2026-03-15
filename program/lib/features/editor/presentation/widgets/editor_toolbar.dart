import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../state/editor_controller.dart';

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    required this.controller,
    required this.onExportPng,
    required this.onExportPdf,
    required this.onToolUnavailable,
    super.key,
  });

  final EditorController controller;
  final VoidCallback onExportPng;
  final VoidCallback onExportPdf;
  final ValueChanged<DrawingTool> onToolUnavailable;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: AppColors.toolbar,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _toolButton(
                  icon: Icons.edit,
                  label: 'Pen',
                  tool: DrawingTool.pen,
                ),
                _toolButton(
                  icon: Icons.create_outlined,
                  label: 'Pencil',
                  tool: DrawingTool.pencil,
                ),
                _toolButton(
                  icon: Icons.border_color_outlined,
                  label: 'Highlighter',
                  tool: DrawingTool.highlighter,
                ),
                _toolButton(
                  icon: Icons.auto_fix_off,
                  label: 'Eraser',
                  tool: DrawingTool.eraser,
                ),
                _toolButton(
                  icon: Icons.select_all,
                  label: 'Lasso',
                  tool: DrawingTool.lasso,
                ),
                _toolButton(
                  icon: Icons.square_foot,
                  label: 'Shapes',
                  tool: DrawingTool.shape,
                ),
                _toolButton(
                  icon: Icons.text_fields,
                  label: 'Text',
                  tool: DrawingTool.text,
                ),
                _toolButton(
                  icon: Icons.image_outlined,
                  label: 'Image',
                  tool: DrawingTool.image,
                ),
                const SizedBox(width: 12),
                for (final color in AppColors.inkPalette)
                  _colorDot(
                    color: color,
                    selected: controller.inkColor == color,
                    onTap: () => controller.setColor(color),
                  ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 140,
                  child: Slider(
                    value: controller.strokeWidth,
                    min: 1,
                    max: 14,
                    onChanged: controller.setStrokeWidth,
                  ),
                ),
                const SizedBox(width: 12),
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
          ),
        );
      },
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String label,
    required DrawingTool tool,
    bool available = true,
  }) {
    final selected = controller.tool == tool;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: IconButton(
        icon: Icon(icon),
        tooltip: label,
        color: selected ? AppColors.inkBlack : null,
        onPressed: () {
          controller.setTool(tool);
          if (!available) {
            onToolUnavailable(tool);
          }
        },
      ),
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
        margin: const EdgeInsets.only(right: 6),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected ? AppColors.inkBlack : Colors.transparent,
            width: 2,
          ),
        ),
      ),
    );
  }
}
