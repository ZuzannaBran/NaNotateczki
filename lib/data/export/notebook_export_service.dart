import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/theme/app_colors.dart';
import '../../features/editor/state/editor_controller.dart';
import '../../features/notebook/domain/drawing_tool.dart';
import '../../features/notebook/domain/image_block.dart';
import '../../features/notebook/domain/ink_stroke.dart';
import '../../features/notebook/domain/notebook.dart';
import '../../features/notebook/domain/notebook_kind.dart';
import '../../features/notebook/domain/note_page.dart';
import '../../features/notebook/domain/text_block.dart';

enum NotebookExportFormat { pdf, png }

extension NotebookExportFormatLabel on NotebookExportFormat {
  String get label {
    switch (this) {
      case NotebookExportFormat.pdf:
        return 'PDF';
      case NotebookExportFormat.png:
        return 'PNG images';
    }
  }
}

class NotebookExportService {
  const NotebookExportService._();

  static const double _pixelRatio = 2.0;
  static const double _boardPadding = 96.0;
  static const Size _fallbackPageSize = Size(820, 820 * 297 / 210);

  static Future<String?> exportController(
    EditorController controller,
    NotebookExportFormat format,
  ) {
    final pageSize = controller.layoutPageSize == Size.zero
        ? _fallbackPageSize
        : controller.layoutPageSize;
    final notebook = controller.notebook.copyWith(pages: controller.pages);
    return exportNotebook(notebook, format, pageSize: pageSize);
  }

  static Future<String?> exportNotebook(
    Notebook notebook,
    NotebookExportFormat format, {
    required Size pageSize,
  }) async {
    final baseName = _fileNameBase(notebook.title);
    switch (format) {
      case NotebookExportFormat.pdf:
        return _exportPdf(notebook, pageSize, baseName);
      case NotebookExportFormat.png:
        return _exportPng(notebook, pageSize, baseName);
    }
  }

  static Future<Directory> _exportDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/exports');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<String?> _exportPdf(
    Notebook notebook,
    Size pageSize,
    String baseName,
  ) async {
    final pdf = pw.Document();
    final pages = await _renderNotebook(notebook, pageSize);
    for (final page in pages) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(page.size.width, page.size.height),
          margin: pw.EdgeInsets.zero,
          build: (_) =>
              pw.Image(pw.MemoryImage(page.bytes), fit: pw.BoxFit.fill),
        ),
      );
    }

    final bytes = await pdf.save();
    return _saveBytesAs(
      dialogTitle: 'Save PDF export',
      fileName: '$baseName.pdf',
      extension: 'pdf',
      bytes: bytes,
    );
  }

  static Future<String?> _exportPng(
    Notebook notebook,
    Size pageSize,
    String baseName,
  ) async {
    final pages = await _renderNotebook(notebook, pageSize);
    if (pages.length == 1) {
      return _saveBytesAs(
        dialogTitle: 'Save PNG export',
        fileName: '$baseName.png',
        extension: 'png',
        bytes: pages.single.bytes,
      );
    }

    final initialDirectory = await _initialExportDirectory();
    final selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose folder for PNG export',
      initialDirectory: initialDirectory,
    );
    if (selectedDirectory == null) {
      return null;
    }

    final folder = Directory('$selectedDirectory/$baseName');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    for (var i = 0; i < pages.length; i++) {
      final number = (i + 1).toString().padLeft(2, '0');
      final file = File('${folder.path}/page_$number.png');
      await file.writeAsBytes(pages[i].bytes);
    }
    return folder.path;
  }

  static Future<String?> _saveBytesAs({
    required String dialogTitle,
    required String fileName,
    required String extension,
    required Uint8List bytes,
  }) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      initialDirectory: await _initialExportDirectory(),
      type: FileType.custom,
      allowedExtensions: [extension],
      bytes: _pickerWritesBytes ? bytes : null,
    );
    if (path == null) {
      return null;
    }

    if (_pickerWritesBytes) {
      return path;
    }

    final savePath = _withExtension(path, extension);
    final file = File(savePath);
    await file.writeAsBytes(bytes);
    return file.path;
  }

  static bool get _pickerWritesBytes => Platform.isAndroid || Platform.isIOS;

  static Future<String?> _initialExportDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return null;
    }
    return (await _exportDir()).path;
  }

  static String _withExtension(String path, String extension) {
    final expectedSuffix = '.$extension';
    if (path.toLowerCase().endsWith(expectedSuffix)) {
      return path;
    }
    return '$path$expectedSuffix';
  }

  static Future<List<_RenderedPage>> _renderNotebook(
    Notebook notebook,
    Size pageSize,
  ) async {
    if (notebook.kind == NotebookKind.board) {
      final page = notebook.pages.isEmpty ? _emptyPage() : notebook.pages.first;
      final bounds = _pageContentBounds(page).inflate(_boardPadding);
      final safeBounds = bounds.isFinite && !bounds.isEmpty
          ? bounds
          : const Rect.fromLTWH(-600, -600, 1200, 1200);
      final bytes = await _renderPage(
        page,
        safeBounds.size,
        origin: safeBounds.topLeft,
      );
      return [_RenderedPage(bytes: bytes, size: safeBounds.size)];
    }

    final rendered = <_RenderedPage>[];
    for (final page in notebook.pages) {
      final bytes = await _renderPage(page, pageSize);
      rendered.add(_RenderedPage(bytes: bytes, size: pageSize));
    }
    if (rendered.isEmpty) {
      final bytes = await _renderPage(_emptyPage(), pageSize);
      rendered.add(_RenderedPage(bytes: bytes, size: pageSize));
    }
    return rendered;
  }

  static Future<Uint8List> _renderPage(
    NotePage page,
    Size size, {
    Offset origin = Offset.zero,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(_pixelRatio);
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.paper);
    await _paintImages(canvas, page.imageBlocks, origin);
    _paintTextBlocks(canvas, page.textBlocks, origin);
    _paintStrokes(canvas, page.inkStrokes, origin, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      math.max(1, (size.width * _pixelRatio).ceil()),
      math.max(1, (size.height * _pixelRatio).ceil()),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) {
      throw StateError('Unable to encode export image.');
    }
    return data.buffer.asUint8List();
  }

  static Future<void> _paintImages(
    Canvas canvas,
    List<ImageBlock> blocks,
    Offset origin,
  ) async {
    for (final block in blocks) {
      final image = await _decodeImage(block);
      if (image == null) {
        continue;
      }
      final crop = Rect.fromLTRB(
        block.cropLeft.clamp(0.0, 1.0) * image.width,
        block.cropTop.clamp(0.0, 1.0) * image.height,
        block.cropRight.clamp(0.0, 1.0) * image.width,
        block.cropBottom.clamp(0.0, 1.0) * image.height,
      );
      final visibleWidth =
          block.width * (block.cropRight - block.cropLeft).clamp(0.08, 1.0);
      final visibleHeight =
          block.height * (block.cropBottom - block.cropTop).clamp(0.08, 1.0);
      final dst = Rect.fromLTWH(
        block.position.dx + block.width * block.cropLeft - origin.dx,
        block.position.dy + block.height * block.cropTop - origin.dy,
        visibleWidth,
        visibleHeight,
      );
      canvas.drawImageRect(image, crop, dst, Paint());
      image.dispose();
    }
  }

  static void _paintTextBlocks(
    Canvas canvas,
    List<TextBlock> blocks,
    Offset origin,
  ) {
    for (final block in blocks) {
      final painter = TextPainter(
        text: TextSpan(children: _textSpans(block)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: block.width);
      painter.paint(canvas, block.position - origin + const Offset(6, 4));
    }
  }

  static List<TextSpan> _textSpans(TextBlock block) {
    final decoded = _decodeDelta(block.deltaJson);
    if (decoded == null) {
      return [
        TextSpan(
          text: block.text,
          style: TextStyle(color: block.color, fontSize: block.fontSize),
        ),
      ];
    }

    final spans = <TextSpan>[];
    for (final item in decoded) {
      final insert = item['insert'];
      if (insert is! String) {
        continue;
      }
      final attrs = item['attributes'] is Map<String, dynamic>
          ? item['attributes'] as Map<String, dynamic>
          : const <String, dynamic>{};
      spans.add(
        TextSpan(
          text: insert,
          style: TextStyle(
            color: _colorFromQuill(attrs['color']) ?? block.color,
            fontSize: _fontSizeFromQuill(attrs['size']) ?? block.fontSize,
            fontWeight: attrs['bold'] == true ? FontWeight.bold : null,
            fontStyle: attrs['italic'] == true ? FontStyle.italic : null,
            decoration: _decorationFromQuill(attrs),
          ),
        ),
      );
    }
    if (spans.isNotEmpty) {
      return spans;
    }
    return [
      TextSpan(
        text: block.text,
        style: TextStyle(color: block.color, fontSize: block.fontSize),
      ),
    ];
  }

  static List<Map<String, dynamic>>? _decodeDelta(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) {
        return null;
      }
      return decoded.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return null;
    }
  }

  static void _paintStrokes(
    Canvas canvas,
    List<InkStroke> strokes,
    Offset origin,
    Size size,
  ) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in strokes) {
      _paintStroke(canvas, stroke, origin);
    }
    canvas.restore();
  }

  static void _paintStroke(Canvas canvas, InkStroke stroke, Offset origin) {
    if (stroke.points.isEmpty) {
      return;
    }
    final paint = Paint()
      ..strokeCap = stroke.tool == DrawingTool.highlighter
          ? StrokeCap.square
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.width;
    if (stroke.tool == DrawingTool.eraserBrush) {
      paint
        ..color = Colors.transparent
        ..blendMode = BlendMode.clear;
    } else {
      paint.color = _strokeColor(stroke.color, stroke.tool);
    }

    final path = _buildInkPath(stroke.points, stroke.tool, origin);
    canvas.drawPath(path, paint);
  }

  static Path _buildInkPath(
    List<InkPoint> points,
    DrawingTool tool,
    Offset origin,
  ) {
    final offsets = points.map((point) => point.toOffset() - origin).toList();
    final path = Path();
    if (offsets.isEmpty) {
      return path;
    }
    path.moveTo(offsets.first.dx, offsets.first.dy);
    if (!_shouldSmoothStroke(points, tool)) {
      for (var i = 1; i < offsets.length; i++) {
        path.lineTo(offsets[i].dx, offsets[i].dy);
      }
    } else {
      for (var i = 1; i < offsets.length - 1; i++) {
        final current = offsets[i];
        final next = offsets[i + 1];
        final midpoint = Offset(
          (current.dx + next.dx) / 2,
          (current.dy + next.dy) / 2,
        );
        path.quadraticBezierTo(
          current.dx,
          current.dy,
          midpoint.dx,
          midpoint.dy,
        );
      }
      path.lineTo(offsets.last.dx, offsets.last.dy);
    }
    if (_samePoint(points.first, points.last)) {
      path.close();
    }
    return path;
  }

  static bool _shouldSmoothStroke(List<InkPoint> points, DrawingTool tool) {
    if (tool != DrawingTool.pen && tool != DrawingTool.highlighter) {
      return false;
    }
    if (points.length < 4 || _samePoint(points.first, points.last)) {
      return false;
    }
    var longestSegmentSquared = 0.0;
    for (var i = 0; i < points.length - 1; i++) {
      final distanceSquared =
          (points[i + 1].toOffset() - points[i].toOffset()).distanceSquared;
      longestSegmentSquared = math.max(longestSegmentSquared, distanceSquared);
    }
    return longestSegmentSquared > 64.0;
  }

  static Future<ui.Image?> _decodeImage(ImageBlock block) async {
    Uint8List? bytes = block.bytes;
    if ((bytes == null || bytes.isEmpty) && block.path.isNotEmpty) {
      final file = File(block.path);
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      }
    }
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    buffer.dispose();
    descriptor.dispose();
    codec.dispose();
    return frame.image;
  }

  static Rect _pageContentBounds(NotePage page) {
    Rect? bounds;
    for (final stroke in page.inkStrokes) {
      if (stroke.points.isEmpty) {
        continue;
      }
      var minX = stroke.points.first.dx;
      var minY = stroke.points.first.dy;
      var maxX = minX;
      var maxY = minY;
      for (final point in stroke.points) {
        minX = math.min(minX, point.dx);
        minY = math.min(minY, point.dy);
        maxX = math.max(maxX, point.dx);
        maxY = math.max(maxY, point.dy);
      }
      final extra = math.max(8.0, stroke.width * 0.5 + 4.0);
      bounds = _expand(
        bounds,
        Rect.fromLTRB(minX - extra, minY - extra, maxX + extra, maxY + extra),
      );
    }
    for (final block in page.textBlocks) {
      bounds = _expand(
        bounds,
        Rect.fromLTWH(
          block.position.dx,
          block.position.dy,
          block.width,
          math.max(44.0, block.fontSize * 2.8),
        ),
      );
    }
    for (final block in page.imageBlocks) {
      bounds = _expand(
        bounds,
        Rect.fromLTWH(
          block.position.dx,
          block.position.dy,
          block.width,
          block.height,
        ),
      );
    }
    return bounds ?? const Rect.fromLTWH(-600, -600, 1200, 1200);
  }

  static Rect _expand(Rect? current, Rect rect) {
    return current == null ? rect : current.expandToInclude(rect);
  }

  static Color _strokeColor(Color base, DrawingTool tool) {
    if (tool == DrawingTool.highlighter) {
      return base.withValues(alpha: 0.5);
    }
    return base;
  }

  static Color? _colorFromQuill(Object? value) {
    if (value is! String || !value.startsWith('#')) {
      return null;
    }
    final hex = value.substring(1);
    final parsed = int.tryParse(hex.length == 6 ? 'ff$hex' : hex, radix: 16);
    return parsed == null ? null : Color(parsed);
  }

  static double? _fontSizeFromQuill(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static TextDecoration? _decorationFromQuill(Map<String, dynamic> attrs) {
    final decorations = <TextDecoration>[];
    if (attrs['underline'] == true) {
      decorations.add(TextDecoration.underline);
    }
    if (attrs['strike'] == true) {
      decorations.add(TextDecoration.lineThrough);
    }
    return decorations.isEmpty ? null : TextDecoration.combine(decorations);
  }

  static bool _samePoint(InkPoint a, InkPoint b) {
    return a.dx == b.dx && a.dy == b.dy;
  }

  static NotePage _emptyPage() {
    return NotePage(
      id: 'export-empty',
      title: 'Empty',
      textBlocks: const [],
      imageBlocks: const [],
      inkStrokes: const [],
      isBookmarked: false,
      indexTabs: const [],
    );
  }

  static String _fileNameBase(String title) {
    final cleaned = title
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final name = cleaned.isEmpty ? 'notatek_export' : cleaned;
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return '${name}_$timestamp';
  }
}

class _RenderedPage {
  const _RenderedPage({required this.bytes, required this.size});

  final Uint8List bytes;
  final Size size;
}
