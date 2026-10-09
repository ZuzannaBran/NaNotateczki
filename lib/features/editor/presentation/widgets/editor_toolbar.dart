import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../data/export/notebook_export_service.dart';
import '../../../notebook/domain/drawing_tool.dart';
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
        final canDelete =
            controller.activeTextBlockId != null ||
            controller.activeImageBlockId != null ||
            (controller.lassoSelection?.isEmpty == false);
        return Padding(
          padding: const EdgeInsets.fromLTRB(52, 8, 52, 8),
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              key: const ValueKey('editor-toolbar-panel'),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 3),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _toolButton(
                      icon: Icons.brush_outlined,
                      label: 'Pen',
                      tool: DrawingTool.pen,
                    ),
                    _toolButton(
                      icon: Icons.edit_outlined,
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
                      icon: Icons.highlight_alt_outlined,
                      label: 'Lasso / Select',
                      tool: DrawingTool.lasso,
                    ),
                    _toolButton(
                      icon: Icons.open_with,
                      label: 'Move',
                      tool: DrawingTool.edit,
                    ),
                    _actionButton(
                      icon: Icons.delete_outline,
                      label: 'Delete',
                      isActive: false,
                      onPressed: canDelete
                          ? controller.deleteActiveElement
                          : null,
                    ),
                    _actionButton(
                      icon: Icons.add_circle_outline,
                      label: 'Insert',
                      isActive: false,
                      onPressed: onInsertPressed,
                    ),
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
                    ValueListenableBuilder<int>(
                      valueListenable: controller.historyRevision,
                      builder: (context, _, _) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.undo, size: 20),
                            onPressed: controller.canUndo
                                ? controller.undo
                                : null,
                            tooltip: 'Undo',
                          ),
                          IconButton(
                            icon: const Icon(Icons.redo, size: 20),
                            onPressed: controller.canRedo
                                ? controller.redo
                                : null,
                            tooltip: 'Redo',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _exportButton(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _exportButton() {
    return PopupMenuButton<NotebookExportFormat>(
      tooltip: 'Export',
      icon: const Icon(Icons.ios_share, size: 20),
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
      isActive: false,
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
    required VoidCallback? onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: label,
        color: isActive
            ? AppColors.inkBlack
            : AppColors.inkBlack.withValues(alpha: 0.72),
        style: _toolHighlightStyle(isActive),
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
        icon: Icon(icon, size: 20),
        tooltip: label,
        color: selected
            ? AppColors.inkBlack
            : AppColors.inkBlack.withValues(alpha: 0.72),
        style: _toolHighlightStyle(selected),
        onPressed: onPressed ?? () => controller.setTool(tool),
      ),
    );
  }

  ButtonStyle _toolHighlightStyle(bool selected) {
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (selected) {
          return AppColors.inkBlack.withValues(alpha: 0.07);
        }
        return null;
      }),
      overlayColor: WidgetStateProperty.all(
        AppColors.inkBlack.withValues(alpha: 0.05),
      ),
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
            color: isSelected
                ? AppColors.inkBlack
                : AppColors.inkBlack.withValues(alpha: 0.72),
            style: _toolHighlightStyle(isSelected),
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
            icon: Icon(_shapeIcon(activeTool), size: 20),
            tooltip: _shapeLabel(activeTool),
            color: isSelected
                ? AppColors.inkBlack
                : AppColors.inkBlack.withValues(alpha: 0.72),
            style: _toolHighlightStyle(isSelected),
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
        icon: const Icon(Icons.expand_more, size: 18),
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
          Icon(_shapeIcon(tool), size: 19),
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
      onTap: onSelect,
      onDoubleTap: () async {
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
    final hexController = TextEditingController(text: _toHexColor(current));

    final result = await showDialog<Color>(
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

            void syncHex() {
              final nextBase = Color.fromARGB(
                255,
                red.round(),
                green.round(),
                blue.round(),
              );
              final nextPreview = _applyShade(nextBase, shade);
              final hex = _toHexColor(nextPreview);
              hexController.value = hexController.value.copyWith(
                text: hex,
                selection: TextSelection.collapsed(offset: hex.length),
                composing: TextRange.empty,
              );
            }

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
                  SizedBox(
                    width: 180,
                    child: TextField(
                      controller: hexController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'HEX',
                        hintText: '#536783',
                        isDense: true,
                      ),
                      onChanged: (value) {
                        final parsed = _colorFromHex(value);
                        if (parsed == null) {
                          return;
                        }
                        setState(() {
                          red = _toByte(parsed.r).toDouble();
                          green = _toByte(parsed.g).toDouble();
                          blue = _toByte(parsed.b).toDouble();
                          shade = 0.5;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  _channelSlider(
                    label: 'R',
                    value: red,
                    color: Colors.red,
                    onChanged: (value) => setState(() {
                      red = value;
                      syncHex();
                    }),
                  ),
                  _channelSlider(
                    label: 'G',
                    value: green,
                    color: Colors.green,
                    onChanged: (value) => setState(() {
                      green = value;
                      syncHex();
                    }),
                  ),
                  _channelSlider(
                    label: 'B',
                    value: blue,
                    color: Colors.blue,
                    onChanged: (value) => setState(() {
                      blue = value;
                      syncHex();
                    }),
                  ),
                  _channelSlider(
                    label: 'B/W',
                    value: shade * 100,
                    color: Colors.grey,
                    min: 0,
                    max: 100,
                    onChanged: (value) => setState(() {
                      shade = value / 100;
                      syncHex();
                    }),
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
    hexController.dispose();
    return result;
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

  String _toHexColor(Color color) {
    final value = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${value.substring(2).toUpperCase()}';
  }

  Color? _colorFromHex(String value) {
    final normalized = value.replaceAll('#', '').trim();
    if (normalized.length != 6) {
      return null;
    }
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) {
      return null;
    }
    return Color(0xFF000000 | parsed);
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
                size: size * 0.36,
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
      ..strokeWidth = 1.25;
    final areaOutline = Paint()
      ..color = lineColor.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
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
