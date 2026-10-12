import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../notebook/domain/text_block.dart';
import '../../state/editor_controller.dart';
import 'editor_toolbar.dart';

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
          final targetBlockId = block.id;
          final updated = await EditorToolbar.pickColor(
            context,
            block.color,
            editorController.recentColors,
          );
          if (updated != null) {
            editorController.updateActiveTextStyle(
              targetBlockId: targetBlockId,
              color: updated,
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: AppColors.displayInkColor(
                block.color,
                darkMode: Theme.of(context).brightness == Brightness.dark,
              ),
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

}
