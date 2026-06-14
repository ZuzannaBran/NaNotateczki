import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../data/export/notebook_export_service.dart';
import '../../../notebook/domain/drawing_tool.dart';
import '../../../notebook/domain/notebook_kind.dart';
import '../../state/editor_controller.dart';
import '../../state/page_background.dart';
import 'page_background_paint.dart';

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    required this.controller,
    required this.onInsertPressed,
    required this.onExportSelected,
    super.key,
  });

  final EditorController controller;
  final VoidCallback onInsertPressed;
  final ValueChanged<NotebookExportFormat> onExportSelected;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: AppColors.toolbar,
          child: Row(
            children: [
              Expanded(
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
                        icon: Icons.edit,
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
                        icon: Icons.ads_click,
                        label: 'Lasso / Select',
                        tool: DrawingTool.lasso,
                      ),
                      _toolButton(
                        icon: Icons.open_with,
                        label: 'Move',
                        tool: DrawingTool.edit,
                      ),
                      _actionButton(
                        icon: Icons.add,
                        label: 'Insert',
                        isActive: false,
                        onPressed: onInsertPressed,
                      ),
                      if (controller.notebook.kind == NotebookKind.notebook)
                        _indexTabButton(context),
                      _backgroundButton(context),
                      const SizedBox(width: 12),
                      for (var i = 0; i < controller.quickColors.length; i++)
                        _colorDot(
                          context,
                          color: controller.quickColors[i],
                          selected:
                              controller.inkColor == controller.quickColors[i],
                          onSelect: () =>
                              controller.setColor(controller.quickColors[i]),
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
              ),
              const SizedBox(width: 8),
              _exportButton(),
            ],
          ),
        );
      },
    );
  }

  Widget _exportButton() {
    return PopupMenuButton<NotebookExportFormat>(
      tooltip: 'Export',
      icon: const Icon(Icons.ios_share),
      onSelected: onExportSelected,
      itemBuilder: (context) => [
        for (final format in NotebookExportFormat.values)
          PopupMenuItem(
            value: format,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  format == NotebookExportFormat.pdf
                      ? Icons.picture_as_pdf
                      : Icons.image,
                ),
                const SizedBox(width: 8),
                Text(format.label),
              ],
            ),
          ),
      ],
    );
  }

  Widget _indexTabButton(BuildContext context) {
    final hasTab = controller.currentPage.indexTabs.isNotEmpty;
    return _actionButton(
      icon: hasTab ? Icons.bookmark : Icons.bookmark_border,
      label: 'Index tab',
      isActive: hasTab,
      onPressed: () async {
        final color = await _pickColor(
          context,
          controller.inkColor,
          controller.recentColors,
        );
        if (color == null) {
          return;
        }
        if (!context.mounted) {
          return;
        }
        final position = await _pickIndexTabPosition(
          context,
          0.12,
          color: color,
        );
        if (position == null) {
          return;
        }
        controller.addIndexTab(color: color, position: position);
      },
    );
  }

  Widget _backgroundButton(BuildContext context) {
    final settings = controller.currentBackgroundSettings;
    final icon = switch (settings.style) {
      PageBackgroundStyle.blank => Icons.crop_square,
      PageBackgroundStyle.grid => Icons.grid_4x4,
      PageBackgroundStyle.lines => Icons.density_medium,
    };
    return _actionButton(
      icon: icon,
      label: 'Background',
      isActive: settings.style != PageBackgroundStyle.blank,
      onPressed: () => _showBackgroundDialog(context),
    );
  }

  Future<void> _showBackgroundDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final settings = controller.currentBackgroundSettings;
            return AlertDialog(
              title: const Text('Background'),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SegmentedButton<PageBackgroundStyle>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: PageBackgroundStyle.blank,
                          icon: Icon(Icons.crop_square),
                          label: Text('Plain'),
                        ),
                        ButtonSegment(
                          value: PageBackgroundStyle.grid,
                          icon: Icon(Icons.grid_4x4),
                          label: Text('Grid'),
                        ),
                        ButtonSegment(
                          value: PageBackgroundStyle.lines,
                          icon: Icon(Icons.density_medium),
                          label: Text('Lines'),
                        ),
                      ],
                      selected: {settings.style},
                      onSelectionChanged: (selection) {
                        controller.setCurrentBackgroundSettings(
                          settings.copyWith(style: selection.single),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const SizedBox(width: 56, child: Text('Density')),
                        Expanded(
                          child: Slider(
                            value: settings.spacing,
                            min: PageBackgroundSettings.minSpacing,
                            max: PageBackgroundSettings.maxSpacing,
                            divisions: 12,
                            onChanged: (value) {
                              controller.setCurrentBackgroundSettings(
                                settings.copyWith(spacing: value),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    PageBackgroundPreview(settings: settings),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: IconButton(
        icon: Icon(icon),
        tooltip: label,
        color: isActive ? AppColors.inkBlack : null,
        onPressed: onPressed,
      ),
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
            icon: _EraserIcon(
              sparkles: activeTool == DrawingTool.eraserStroke,
              area: activeTool == DrawingTool.eraserArea,
            ),
            tooltip: _eraserLabel(activeTool),
            color: isSelected ? AppColors.inkBlack : null,
            onPressed: () => controller.setTool(activeTool),
          ),
          _selectorMenuButton(
            tooltip: 'Eraser options',
            initialValue: activeTool,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: DrawingTool.eraserBrush,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _EraserIcon(),
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
                    _EraserIcon(sparkles: true),
                    SizedBox(width: 8),
                    Text('Erase stroke'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: DrawingTool.eraserArea,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _EraserIcon(area: true),
                    SizedBox(width: 8),
                    Text('Erase area'),
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
          _selectorMenuButton(
            tooltip: 'Shape options',
            initialValue: activeTool,
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

  Widget _selectorMenuButton({
    required String tooltip,
    required DrawingTool initialValue,
    required PopupMenuItemBuilder<DrawingTool> itemBuilder,
  }) {
    return SizedBox(
      width: 32,
      child: PopupMenuButton<DrawingTool>(
        tooltip: tooltip,
        initialValue: initialValue,
        icon: const Icon(Icons.arrow_drop_down),
        padding: EdgeInsets.zero,
        onSelected: controller.setTool,
        itemBuilder: itemBuilder,
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

  String _eraserLabel(DrawingTool tool) {
    return switch (tool) {
      DrawingTool.eraserStroke => 'Erase stroke',
      DrawingTool.eraserArea => 'Erase area',
      _ => 'Eraser brush',
    };
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

  Future<double?> _pickIndexTabPosition(
    BuildContext context,
    double current, {
    required Color color,
  }) async {
    var position = current.clamp(0.0, 1.0).toDouble();
    return showDialog<double>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Choose tab height'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 180,
                    child: Row(
                      children: [
                        Container(
                          width: 92,
                          height: 160,
                          decoration: BoxDecoration(
                            color: AppColors.paper,
                            border: Border.all(color: AppColors.divider),
                            boxShadow: const [
                              BoxShadow(
                                color: AppColors.shadow,
                                blurRadius: 8,
                                offset: Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                left: -28,
                                top: 8 + position * 136,
                                width: 56,
                                height: 16,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.75),
                                    borderRadius: const BorderRadius.only(
                                      topLeft: Radius.circular(2),
                                      bottomLeft: Radius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Slider(
                            value: position,
                            min: 0,
                            max: 1,
                            divisions: 20,
                            onChanged: (value) =>
                                setState(() => position = value),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(position),
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

class _EraserIcon extends StatelessWidget {
  const _EraserIcon({this.sparkles = false, this.area = false});

  final bool sparkles;
  final bool area;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final size = iconTheme.size ?? 24;
    final backgroundColor = Theme.of(context).colorScheme.surface;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _EraserIconPainter(
              area: area,
              backgroundColor: backgroundColor,
              color: iconTheme.color,
            ),
          ),
          if (sparkles)
            Positioned(
              left: 0,
              top: 0,
              child: Icon(
                Icons.auto_awesome,
                size: size * 0.42,
                color: iconTheme.color,
              ),
            ),
        ],
      ),
    );
  }
}

class _EraserIconPainter extends CustomPainter {
  const _EraserIconPainter({
    required this.area,
    required this.backgroundColor,
    required this.color,
  });

  final bool area;
  final Color backgroundColor;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    final lineColor = color ?? Colors.black87;
    final outline = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final areaOutline = Paint()
      ..color = lineColor.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final body = Paint()
      ..color = Color.alphaBlend(
        lineColor.withValues(alpha: 0.10),
        backgroundColor,
      )
      ..style = PaintingStyle.fill;
    final end = Paint()
      ..color = Color.alphaBlend(
        lineColor.withValues(alpha: 0.30),
        backgroundColor,
      )
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final eraser = Rect.fromLTWH(-w * 0.34, -h * 0.14, w * 0.68, h * 0.28);
    final endCap = Rect.fromLTWH(-w * 0.34, -h * 0.14, w * 0.22, h * 0.28);

    if (area) {
      canvas.drawCircle(
        Offset(w * 0.48, h * 0.62),
        size.shortestSide * 0.29,
        areaOutline,
      );
    }

    canvas.save();
    canvas.translate(w * 0.48, h * 0.62);
    canvas.rotate(-0.7853981633974483);
    canvas.drawRect(eraser, body);
    canvas.drawRect(endCap, end);
    canvas.drawRect(eraser, outline);
    canvas.drawLine(
      Offset(-w * 0.12, -h * 0.14),
      Offset(-w * 0.12, h * 0.14),
      outline,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EraserIconPainter oldDelegate) {
    return oldDelegate.area != area ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.color != color;
  }
}
