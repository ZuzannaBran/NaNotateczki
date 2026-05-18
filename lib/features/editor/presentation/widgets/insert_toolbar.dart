import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

class InsertToolbar extends StatelessWidget {
  const InsertToolbar({
    required this.onPickFile,
    required this.onPaste,
    required this.onClose,
    super.key,
  });

  final VoidCallback onPickFile;
  final VoidCallback onPaste;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppColors.toolbar.withValues(alpha: 0.9),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.attach_file),
              tooltip: 'Attach file',
              onPressed: onPickFile,
            ),
            IconButton(
              icon: const Icon(Icons.content_paste),
              tooltip: 'Paste',
              onPressed: onPaste,
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
