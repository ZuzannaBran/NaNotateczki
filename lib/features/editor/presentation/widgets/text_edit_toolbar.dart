import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;

import '../../../../core/theme/app_colors.dart';
import '../../state/editor_controller.dart';

class TextEditToolbar extends StatelessWidget {
  const TextEditToolbar({
    required this.controller,
    required this.editorController,
    required this.activeTextBlockId,
    super.key,
  });

  final quill.QuillController controller;
  final EditorController editorController;
  final String? activeTextBlockId;

  static const List<String> _fontFamilies = [
    'Times New Roman',
    'Courier',
    'cursive',
    'Serif Bold',
    'Impact',
  ];

  static const List<String> _fontSizes = [
    '12',
    '14',
    '16',
    '18',
    '20',
    '24',
    '28',
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final selectionStyle = controller.getSelectionStyle();
        final isBold = selectionStyle.attributes.containsKey(
          quill.Attribute.bold.key,
        );
        final isItalic = selectionStyle.attributes.containsKey(
          quill.Attribute.italic.key,
        );
        final isUnderline = selectionStyle.attributes.containsKey(
          quill.Attribute.underline.key,
        );
        final currentFont = selectionStyle
            .attributes[quill.Attribute.font.key]
            ?.value
            ?.toString();
        final currentSize = selectionStyle
            .attributes[quill.Attribute.size.key]
            ?.value
            ?.toString();
        final currentColor = selectionStyle
            .attributes[quill.Attribute.color.key]
            ?.value
            ?.toString();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: AppColors.toolbar.withValues(alpha: 0.9),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _styleButton(
                  icon: Icons.format_bold,
                  isActive: isBold,
                  onPressed: () =>
                    _applyFormat(quill.Attribute.bold, isBold),
                ),
                _styleButton(
                  icon: Icons.format_italic,
                  isActive: isItalic,
                  onPressed: () =>
                    _applyFormat(quill.Attribute.italic, isItalic),
                ),
                _styleButton(
                  icon: Icons.format_underline,
                  isActive: isUnderline,
                  onPressed: () =>
                    _applyFormat(quill.Attribute.underline, isUnderline),
                ),
                const SizedBox(width: 8),
                _fontDropdown(currentFont),
                const SizedBox(width: 8),
                _sizeDropdown(currentSize),
                const SizedBox(width: 8),
                _colorPicker(context, currentColor),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete text',
                  onPressed: activeTextBlockId == null
                      ? null
                      : () => editorController
                          .deleteTextBlock(activeTextBlockId!),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _styleButton({
    required IconData icon,
    required bool isActive,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      tooltip: 'Text style',
      color: isActive ? AppColors.inkBlack : null,
      onPressed: onPressed,
      iconSize: 20,
    );
  }

  Widget _fontDropdown(String? currentFont) {
    final value = _fontFamilies.contains(currentFont) ? currentFont : null;
    return DropdownButton<String>(
      value: value,
      hint: const Text('Font'),
      onChanged: (value) {
        if (value == null) {
          return;
        }
        final attribute = quill.Attribute.fromKeyValue('font', value);
        if (attribute == null) {
          return;
        }
        _applyFormat(attribute, false);
      },
      items: _fontFamilies
          .map(
            (font) => DropdownMenuItem(
              value: font,
              child: Text(font),
            ),
          )
          .toList(),
    );
  }

  Widget _sizeDropdown(String? currentSize) {
    final value = _fontSizes.contains(currentSize) ? currentSize : null;
    return DropdownButton<String>(
      value: value,
      hint: const Text('Size'),
      onChanged: (value) {
        if (value == null) {
          return;
        }
        final attribute = quill.Attribute.fromKeyValue('size', value);
        if (attribute == null) {
          return;
        }
        _applyFormat(attribute, false);
      },
      items: _fontSizes
          .map(
            (size) => DropdownMenuItem(
              value: size,
              child: Text(size),
            ),
          )
          .toList(),
    );
  }

  Widget _colorPicker(BuildContext context, String? currentValue) {
    return GestureDetector(
      onTap: () async {
        final base = _colorFromHex(currentValue) ?? AppColors.inkBlack;
        final updated = await _pickColor(
          context,
          base,
          editorController.recentColors,
        );
        if (updated == null) {
          return;
        }
        final attribute = quill.Attribute.fromKeyValue(
          'color',
          _toHex(updated),
        );
        if (attribute == null) {
          return;
        }
        _applyFormat(attribute, false);
      },
      child: Row(
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: _colorFromHex(currentValue) ?? AppColors.inkBlack,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  String _toHex(Color color) {
    final value = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${value.substring(2)}';
  }

  Color? _colorFromHex(String? value) {
    if (value == null) {
      return null;
    }
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
                    onChanged: (value) =>
                        setState(() => shade = value / 100),
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

  int _toByte(double component) {
    return (component * 255.0).round().clamp(0, 255).toInt();
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

  void _applyFormat(quill.Attribute attribute, bool isActive) {
    final resolved = _resolveAttribute(attribute, isActive);
    _storeLastTextStyle(attribute, resolved);
    final selection = controller.selection;
    if (!selection.isCollapsed) {
      controller.formatSelection(resolved);
      return;
    }
    final docLength = controller.document.length;
    if (docLength == 0) {
      return;
    }
    final end = (docLength - 1).clamp(0, docLength).toInt();
    controller.updateSelection(
      TextSelection(baseOffset: 0, extentOffset: end),
      quill.ChangeSource.local,
    );
    controller.formatSelection(resolved);
    controller.updateSelection(selection, quill.ChangeSource.local);
  }

  quill.Attribute _resolveAttribute(
    quill.Attribute attribute,
    bool isActive,
  ) {
    if (!isActive) {
      return attribute;
    }
    return quill.Attribute.fromKeyValue(attribute.key, null) ?? attribute;
  }

  void _storeLastTextStyle(
    quill.Attribute original,
    quill.Attribute resolved,
  ) {
    if (original.key == quill.Attribute.font.key) {
      editorController.setLastTextFontFamily(
        resolved.value?.toString(),
      );
      return;
    }
    if (original.key == quill.Attribute.size.key) {
      final parsed = double.tryParse(resolved.value?.toString() ?? '');
      if (parsed != null) {
        editorController.setLastTextFontSize(parsed);
      }
      return;
    }
    if (original.key == quill.Attribute.color.key) {
      final color = _colorFromHex(resolved.value?.toString());
      if (color != null) {
        editorController.setLastTextColor(color);
      }
    }
  }
}
