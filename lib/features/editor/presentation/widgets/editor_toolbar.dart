import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../state/editor_controller.dart';

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    required this.controller,
    super.key,
  });

  final EditorController controller;

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
                _eraserSelector(),
                _shapeSelector(),
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

  Widget _eraserSelector() {
    final activeTool = controller.tool.isEraser
      ? controller.tool
      : controller.lastEraserTool;
    final isSelected = controller.tool.isEraser;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            tooltip: activeTool == DrawingTool.eraserStroke
                ? 'Erase stroke'
                : 'Eraser brush',
            color: isSelected ? AppColors.inkBlack : null,
            onPressed: () => controller.setTool(activeTool),
          ),
          PopupMenuButton<DrawingTool>(
            tooltip: 'Eraser options',
            initialValue: activeTool,
            icon: const Icon(Icons.arrow_drop_down),
            onSelected: controller.setTool,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: DrawingTool.eraserBrush,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cleaning_services),
                    SizedBox(width: 8),
                    Text('Eraser brush'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: DrawingTool.eraserStroke,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_fix_off),
                    SizedBox(width: 8),
                    Text('Erase stroke'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _shapeSelector() {
    final activeTool = controller.tool.isShape
        ? controller.tool
        : controller.lastShapeTool;
    final isSelected = controller.tool.isShape;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(_shapeIcon(activeTool)),
            tooltip: _shapeLabel(activeTool),
            color: isSelected ? AppColors.inkBlack : null,
            onPressed: () => controller.setTool(activeTool),
          ),
          PopupMenuButton<DrawingTool>(
            tooltip: 'Shape options',
            initialValue: activeTool,
            icon: const Icon(Icons.arrow_drop_down),
            onSelected: controller.setTool,
            itemBuilder: (context) => [
              _shapeItem(DrawingTool.line),
              _shapeItem(DrawingTool.arrow),
              _shapeItem(DrawingTool.blockArrow),
              _shapeItem(DrawingTool.rectangle),
              _shapeItem(DrawingTool.square),
              _shapeItem(DrawingTool.triangle),
              _shapeItem(DrawingTool.ellipse),
              _shapeItem(DrawingTool.circle),
            ],
          ),
        ],
      ),
    );
  }

  PopupMenuItem<DrawingTool> _shapeItem(DrawingTool tool) {
    return PopupMenuItem(
      value: tool,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_shapeIcon(tool)),
          const SizedBox(width: 8),
          Text(_shapeLabel(tool)),
        ],
      ),
    );
  }

  IconData _shapeIcon(DrawingTool tool) {
    switch (tool) {
      case DrawingTool.line:
        return Icons.show_chart;
      case DrawingTool.arrow:
        return Icons.arrow_right_alt;
      case DrawingTool.blockArrow:
        return Icons.arrow_forward;
      case DrawingTool.rectangle:
        return Icons.rectangle_outlined;
      case DrawingTool.square:
        return Icons.crop_square;
      case DrawingTool.ellipse:
        return Icons.panorama_fish_eye;
      case DrawingTool.circle:
        return Icons.circle_outlined;
      case DrawingTool.triangle:
        return Icons.change_history;
      default:
        return Icons.show_chart;
    }
  }

  String _shapeLabel(DrawingTool tool) {
    switch (tool) {
      case DrawingTool.line:
        return 'Line';
      case DrawingTool.arrow:
        return 'Arrow';
      case DrawingTool.blockArrow:
        return 'Block Arrow';
      case DrawingTool.rectangle:
        return 'Rectangle';
      case DrawingTool.square:
        return 'Square';
      case DrawingTool.ellipse:
        return 'Ellipse';
      case DrawingTool.circle:
        return 'Circle';
      case DrawingTool.triangle:
        return 'Triangle';
      default:
        return 'Shape';
    }
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
    var red = _toByte(current.r).toDouble();
    var green = _toByte(current.g).toDouble();
    var blue = _toByte(current.b).toDouble();
    var shade = 0.5;

    return showDialog<Color>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final base = Color.fromARGB(
              255,
              red.round(),
              green.round(),
              blue.round(),
            );
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
        (_toByte(base.r) * t).round(),
        (_toByte(base.g) * t).round(),
        (_toByte(base.b) * t).round(),
      );
    }
    final t = (shade - 0.5) / 0.5;
    final r = _toByte(base.r);
    final g = _toByte(base.g);
    final b = _toByte(base.b);
    return Color.fromARGB(
      255,
      (r + (255 - r) * t).round(),
      (g + (255 - g) * t).round(),
      (b + (255 - b) * t).round(),
    );
  }

  int _toByte(double component) {
    return (component * 255.0).round().clamp(0, 255).toInt();
  }
}
