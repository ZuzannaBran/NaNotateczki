import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../state/editor_controller.dart';
import 'widgets/drawing_canvas.dart';
import 'widgets/editor_toolbar.dart';
import 'widgets/page_overlay.dart';
import 'widgets/page_strip.dart';
import 'widgets/text_edit_toolbar.dart';

class EditorScreen extends StatelessWidget {
  EditorScreen({super.key});

  final GlobalKey _canvasKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();

    return Scaffold(
      appBar: AppBar(
        title: Text(controller.notebook.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_outline),
            tooltip: 'Bookmark page',
            onPressed: controller.toggleBookmark,
          ),
        ],
      ),
      body: Column(
        children: [
          EditorToolbar(
            controller: controller,
          ),
          if (controller.activeTextController != null)
            TextEditToolbar(
              controller: controller.activeTextController!,
              editorController: controller,
              activeTextBlockId: controller.activeTextBlockId,
            ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.paper,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: AppColors.shadow,
                    blurRadius: 12,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: RepaintBoundary(
                  key: _canvasKey,
                  child: Stack(
                    children: [
                      const DrawingCanvas(),
                      PageOverlay(controller: controller),
                    ],
                  ),
                ),
              ),
            ),
          ),
          PageStrip(controller: controller),
        ],
      ),
    );
  }

}
