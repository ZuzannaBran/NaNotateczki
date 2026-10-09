import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';

class TextEditToolbar extends StatelessWidget {
  const TextEditToolbar({
    required this.editorController,
    required this.block,
    super.key,
  });

  static const String _themeFontKey = '__theme__';
  static const List<String> _fontFamilies = [
    _themeFontKey,
    'Times New Roman',
    'Courier New',
    'Impact',
  ];
  static const List<int> _fontSizes = [
    12,
    14,
    16,
    18,
    20,
    24,
    28,
    32,
    36,
    48,
    64,
    72,
    96,
  ];

  final EditorController editorController;
  final TextBlock block;

  @override
  Widget build(BuildContext context) {
    final inline = _firstInlineAttributes(block.deltaJson);
    final paragraph = _firstParagraphAttributes(block.deltaJson);
    final currentFont = inline['font']?.toString();
    final currentAlign = paragraph['align']?.toString() ?? 'left';
    final currentSize = block.fontSize.round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(52, 0, 52, 8),
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          key: const ValueKey('text-toolbar-panel'),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 2),
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
                _styleButton(
                  icon: Icons.format_bold,
                  tooltip: 'Bold',
                  isActive: inline['bold'] == true,
                  onPressed: () => editorController.updateActiveTextStyle(
                    bold: inline['bold'] != true,
                  ),
                ),
                _styleButton(
                  icon: Icons.format_italic,
                  tooltip: 'Italic',
                  isActive: inline['italic'] == true,
                  onPressed: () => editorController.updateActiveTextStyle(
                    italic: inline['italic'] != true,
                  ),
                ),
                _styleButton(
                  icon: Icons.format_underline,
                  tooltip: 'Underline',
                  isActive: inline['underline'] == true,
                  onPressed: () => editorController.updateActiveTextStyle(
                    underline: inline['underline'] != true,
                  ),
                ),
                _styleButton(
                  icon: Icons.strikethrough_s,
                  tooltip: 'Strikethrough',
                  isActive: inline['strike'] == true,
                  onPressed: () => editorController.updateActiveTextStyle(
                    strike: inline['strike'] != true,
                  ),
                ),
                const SizedBox(width: 6),
                _fontDropdown(currentFont),
                const SizedBox(width: 8),
                _sizeDropdown(currentSize),
                const SizedBox(width: 8),
                _colorPicker(context),
                const SizedBox(width: 8),
                _alignmentButton(
                  icon: Icons.format_align_left,
                  tooltip: 'Align left',
                  alignment: 'left',
                  current: currentAlign,
                ),
                _alignmentButton(
                  icon: Icons.format_align_center,
                  tooltip: 'Align center',
                  alignment: 'center',
                  current: currentAlign,
                ),
                _alignmentButton(
                  icon: Icons.format_align_right,
                  tooltip: 'Align right',
                  alignment: 'right',
                  current: currentAlign,
                ),
                _alignmentButton(
                  icon: Icons.format_align_justify,
                  tooltip: 'Justify',
                  alignment: 'justify',
                  current: currentAlign,
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.format_clear),
                  tooltip: 'Clear block formatting',
                  iconSize: 20,
                  onPressed: () => editorController.updateActiveTextStyle(
                    clearDecorations: true,
                    clearFontFamily: true,
                    alignment: 'left',
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete text',
                  iconSize: 20,
                  onPressed: () => editorController.deleteTextBlock(block.id),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _styleButton({
    required IconData icon,
    required String tooltip,
    required bool isActive,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      color: isActive ? AppColors.inkBlack : null,
      onPressed: onPressed,
      iconSize: 20,
    );
  }

  Widget _alignmentButton({
    required IconData icon,
    required String tooltip,
    required String alignment,
    required String current,
  }) {
    return _styleButton(
      icon: icon,
      tooltip: tooltip,
      isActive: current == alignment,
      onPressed: () {
        editorController.updateActiveTextStyle(alignment: alignment);
      },
    );
  }

  Widget _fontDropdown(String? currentFont) {
    final values = <String>[..._fontFamilies];
    if (currentFont != null && !values.contains(currentFont)) {
      values.add(currentFont);
    }
    final value = currentFont ?? _themeFontKey;

    return DropdownButton<String>(
      value: value,
      isDense: true,
      onChanged: (next) {
        if (next == null) {
          return;
        }
        if (next == _themeFontKey) {
          editorController.updateActiveTextStyle(clearFontFamily: true);
          return;
        }
        editorController.updateActiveTextStyle(fontFamily: next);
      },
      items: values
          .map(
            (font) => DropdownMenuItem<String>(
              value: font,
              child: Text(
                font == _themeFontKey ? 'Georgia' : font,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _sizeDropdown(int currentSize) {
    final values = <int>{..._fontSizes, currentSize}.toList()..sort();

    return DropdownButton<int>(
      value: currentSize,
      isDense: true,
      onChanged: (next) {
        if (next == null) {
          return;
        }
        editorController.updateActiveTextStyle(fontSize: next.toDouble());
      },
      items: values
          .map(
            (size) => DropdownMenuItem<int>(
              value: size,
              child: Text('$size', style: const TextStyle(fontSize: 13)),
            ),
          )
          .toList(),
    );
  }

  Widget _colorPicker(BuildContext context) {
    return Tooltip(
      message: 'Text color',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          final updated = await _pickColor(
            context,
            block.color,
            editorController.recentColors,
          );
          if (updated != null) {
            editorController.updateActiveTextStyle(color: updated);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: block.color,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.divider),
            ),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _firstInlineAttributes(String? deltaJson) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return const <String, dynamic>{};
      }
      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }
        final op = Map<String, dynamic>.from(raw);
        final insert = op['insert'];
        if (insert is! String || insert.replaceAll('\n', '').isEmpty) {
          continue;
        }
        final attributes = op['attributes'];
        return attributes is Map
            ? Map<String, dynamic>.from(attributes)
            : const <String, dynamic>{};
      }
    } catch (_) {
      return const <String, dynamic>{};
    }
    return const <String, dynamic>{};
  }

  Map<String, dynamic> _firstParagraphAttributes(String? deltaJson) {
    if (deltaJson == null || deltaJson.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) {
        return const <String, dynamic>{};
      }
      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }
        final op = Map<String, dynamic>.from(raw);
        final insert = op['insert'];
        if (insert is! String || !insert.contains('\n')) {
          continue;
        }
        final attributes = op['attributes'];
        return attributes is Map
            ? Map<String, dynamic>.from(attributes)
            : const <String, dynamic>{};
      }
    } catch (_) {
      return const <String, dynamic>{};
    }
    return const <String, dynamic>{};
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
    final hexController = TextEditingController(
      text: _toHex(current).toUpperCase(),
    );

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
              final hex = _toHex(nextPreview).toUpperCase();
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
}
