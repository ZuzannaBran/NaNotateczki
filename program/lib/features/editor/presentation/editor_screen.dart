import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../state/editor_controller.dart';
import 'widgets/drawing_canvas.dart';
import 'widgets/editor_toolbar.dart';
import 'widgets/page_overlay.dart';
import 'widgets/page_strip.dart';

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
            onExportPng: () => _exportPng(context),
            onExportPdf: () => _exportPdf(context),
            onToolUnavailable: (tool) => _showToolHint(context, tool),
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
                      IgnorePointer(
                        ignoring:
                            controller.tool == DrawingTool.text ||
                            controller.tool == DrawingTool.image,
                        child: DrawingCanvas(controller: controller),
                      ),
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

  Future<void> _exportPng(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await _capturePngBytes();
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Nothing to export yet.')),
      );
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}/note_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes);
    messenger.showSnackBar(
      SnackBar(content: Text('Saved PNG to ${file.path}')),
    );
  }

  Future<void> _exportPdf(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await _capturePngBytes();
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Nothing to export yet.')),
      );
      return;
    }
    final doc = pw.Document();
    final image = pw.MemoryImage(bytes);
    doc.addPage(pw.Page(build: (context) => pw.Center(child: pw.Image(image))));
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}/note_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes(await doc.save());
    messenger.showSnackBar(
      SnackBar(content: Text('Saved PDF to ${file.path}')),
    );
  }

  Future<Uint8List?> _capturePngBytes() async {
    final boundary = _canvasKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      return null;
    }
    final image = await boundary.toImage(pixelRatio: 3.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  void _showToolHint(BuildContext context, DrawingTool tool) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${tool.name} tool is coming soon.')),
    );
  }
}
