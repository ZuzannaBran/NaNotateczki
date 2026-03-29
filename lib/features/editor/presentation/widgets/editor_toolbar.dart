import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../state/editor_controller.dart';

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    required this.controller,
    required this.onExportPng,
    required this.onExportPdf,
    super.key,
  });

  final EditorController controller;
  final VoidCallback onExportPng;
  final VoidCallback onExportPdf;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: AppColors.toolbar,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _toolButton(
                  icon: Icons.brush_outlined,
                  label: 'Pen',
                  tool: DrawingTool.pen,
                ),
                _toolButton(
                  icon: Icons.highlight,
                  label: 'Highlighter',
                  tool: DrawingTool.highlighter,
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
                for (var i = 0; i < controller.quickColors.length; i++)
                  _colorDot(
                    context,
                    color: controller.quickColors[i],
                    selected: controller.inkColor == controller.quickColors[i],
                    onSelect: () => controller.setColor(
                      controller.quickColors[i],
                    ),
                    onEdit: (color) => controller.setQuickColor(i, color),
                  ),
                SizedBox(
                  width: 140,
                  child: Slider(
                    value: controller.inkStrokeWidth,
                    min: 1.0,
                    max: 12.0,
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
    VoidCallback? onPressed,
  }) {
    final selected = controller.tool == tool;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: IconButton(
        icon: Icon(icon),
        tooltip: label,
        color: selected ? AppColors.inkBlack : null,
        onPressed: onPressed ?? () => controller.setTool(tool),
      ),
    );
  }

  Widget _colorDot(
    BuildContext context, {
    required Color color,
    required bool selected,
    required VoidCallback onSelect,
    required ValueChanged<Color> onEdit,
  }) {
    return GestureDetector(
      onTap: () async {
        final updated = await _pickColor(
          context,
          color,
          controller.recentColors,
        );
        if (updated == null) {
          return;
        }
        onEdit(updated);
      },
      onLongPress: onSelect,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        width: 24,
        height: 24,
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

  Future<Color?> _pickColor(
    BuildContext context,
    Color current,
    List<Color> recentColors,
  ) async {
    var red = current.red.toDouble();
    var green = current.green.toDouble();
    var blue = current.blue.toDouble();
    var shade = 0.5;

    return showDialog<Color>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final base = Color.fromARGB(255, red.round(), green.round(), blue.round());
            final preview = _applyShade(base, shade);
            return AlertDialog(
              title: const Text('Pick color'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: preview,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.divider),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _channelSlider(
                    label: 'R',
                    value: red,
                    color: Colors.red,
                    onChanged: (value) => setState(() => red = value),
                  ),
                  _channelSlider(
                    label: 'G',
                    value: green,
                    color: Colors.green,
                    onChanged: (value) => setState(() => green = value),
                  ),
                  _channelSlider(
                    label: 'B',
                    value: blue,
                    color: Colors.blue,
                    onChanged: (value) => setState(() => blue = value),
                  ),
                  _channelSlider(
                    label: 'B/W',
                    value: shade * 100,
                    color: Colors.grey,
                    min: 0,
                    max: 100,
                    onChanged: (value) => setState(() => shade = value / 100),
                  ),
                  if (recentColors.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Recent',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final color in recentColors)
                          GestureDetector(
                            onTap: () => Navigator.of(context).pop(color),
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: color,
                                border: Border.all(color: AppColors.divider),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(preview),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _channelSlider({
    required String label,
    required double value,
    required Color color,
    double min = 0,
    double max = 255,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 18, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            activeColor: color,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Color _applyShade(Color base, double shade) {
    if (shade == 0.5) {
      return base;
    }
    if (shade < 0.5) {
      final t = shade / 0.5;
      return Color.fromARGB(
        255,
        (base.red * t).round(),
        (base.green * t).round(),
        (base.blue * t).round(),
      );
    }
    final t = (shade - 0.5) / 0.5;
    return Color.fromARGB(
      255,
      (base.red + (255 - base.red) * t).round(),
      (base.green + (255 - base.green) * t).round(),
      (base.blue + (255 - base.blue) * t).round(),
    );
  }
}
