import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart' as quill_delta;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/ink_stroke.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/text_block.dart';
import 'editor_actions.dart';

class EditorController extends ChangeNotifier {
  static const double minViewScale = 0.35;
  static const double maxViewScale = 4.0;

  EditorController({required this.repository, required this.notebook}) {
    pages = notebook.pages;
    currentPageIndex = 0;
    _loadEditorPrefs();
  }

  final NotebookRepository repository;
  final Notebook notebook;
  final Uuid _uuid = const Uuid();
  final ImagePicker _imagePicker = ImagePicker();

  late List<NotePage> pages;
  int currentPageIndex = 0;
  DrawingTool tool = DrawingTool.pen;
  DrawingTool lastEraserTool = DrawingTool.eraserBrush;
  DrawingTool lastShapeTool = DrawingTool.line;
  Color inkColor = const Color(0xFF1E1E1E);
  double inkStrokeWidth = 2.5;
  final List<Color> quickColors = [
    Color(0xFF1E1E1E),
    Color(0xFFD32F2F),
    Color(0xFF2E7D32),
  ];
  final List<Color> recentColors = <Color>[];

  final List<EditorAction> _undoActions = <EditorAction>[];
  final List<EditorAction> _redoActions = <EditorAction>[];
  Timer? _prefsSaveDebounce;

  String? lastTextFontFamily;
  double lastTextFontSize = 18.0;
  Color lastTextColor = const Color(0xFF1E1E1E);

  String? activeTextBlockId;
  quill.QuillController? activeTextController;
  bool _suppressBackgroundTap = false;
  double viewScale = 1.0;
  Offset viewPan = Offset.zero;

  NotePage get currentPage => pages[currentPageIndex];

  bool get canUndo => _undoActions.isNotEmpty;
  bool get canRedo => _redoActions.isNotEmpty;
  Rect get contentBounds => _computeContentBounds();

  void setViewTransform({Offset? pan, double? scale}) {
    final targetScale = (scale ?? viewScale)
        .clamp(minViewScale, maxViewScale)
        .toDouble();
    final targetPan = pan ?? viewPan;
    final changed = targetScale != viewScale || targetPan != viewPan;
    if (!changed) {
      return;
    }
    viewScale = targetScale;
    viewPan = targetPan;
    notifyListeners();
  }

  void panBy(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }
    setViewTransform(pan: viewPan + delta);
  }

  void zoomBy(double factor, {required Offset focalPoint}) {
    if (factor == 1.0) {
      return;
    }
    final currentScale = viewScale <= 0 ? 1.0 : viewScale;
    final worldAtFocal = (focalPoint - viewPan) / currentScale;
    final targetScale = (currentScale * factor)
        .clamp(minViewScale, maxViewScale)
        .toDouble();
    final targetPan = focalPoint - (worldAtFocal * targetScale);
    setViewTransform(scale: targetScale, pan: targetPan);
  }

  Offset viewportToWorld(Offset viewportPoint) {
    final safeScale = viewScale <= 0 ? 1.0 : viewScale;
    return (viewportPoint - viewPan) / safeScale;
  }

  Offset worldToViewport(Offset worldPoint) {
    return worldPoint * viewScale + viewPan;
  }

  NotePage pageAt(int index) {
    return pages[index];
  }

  TextBlock? findTextBlockById(String id) {
    for (final page in pages) {
      for (final block in page.textBlocks) {
        if (block.id == id) {
          return block;
        }
      }
    }
    return null;
  }

  ImageBlock? findImageBlockById(String id) {
    for (final page in pages) {
      for (final block in page.imageBlocks) {
        if (block.id == id) {
          return block;
        }
      }
    }
    return null;
  }

  void _ensurePageSelected(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= pages.length) {
      return;
    }
    if (pageIndex == currentPageIndex) {
      return;
    }
    setCurrentPage(pageIndex);
  }

  Future<String?> handleTapOnPage(int pageIndex, Offset point) async {
    _ensurePageSelected(pageIndex);
    return handleTap(point);
  }

  void addTextBlockOnPage(int pageIndex, Offset position) {
    _ensurePageSelected(pageIndex);
    addTextBlock(position);
  }

  void updateTextBlockContentOnPage(
    int pageIndex,
    TextBlock before, {
    required String plainText,
    required String deltaJson,
  }) {
    _ensurePageSelected(pageIndex);
    updateTextBlockContent(before, plainText: plainText, deltaJson: deltaJson);
  }

  void updateTextBlockPositionOnPage(
    int pageIndex,
    String id,
    Offset position,
  ) {
    _ensurePageSelected(pageIndex);
    updateTextBlockPosition(id, position);
  }

  void deleteTextBlockOnPage(int pageIndex, String id) {
    _ensurePageSelected(pageIndex);
    deleteTextBlock(id);
  }

  void commitTextMoveOnPage(
    int pageIndex,
    String id,
    Offset start,
    Offset end,
  ) {
    _ensurePageSelected(pageIndex);
    commitTextMove(id, start, end);
  }

  Future<String?> addImageBlockOnPage(int pageIndex, Offset position) async {
    _ensurePageSelected(pageIndex);
    return addImageBlock(position);
  }

  Future<String?> runOcrForImageOnPage(int pageIndex, ImageBlock block) async {
    _ensurePageSelected(pageIndex);
    return runOcrForImage(block);
  }

  void updateImageBlockPositionOnPage(
    int pageIndex,
    String id,
    Offset position,
  ) {
    _ensurePageSelected(pageIndex);
    updateImageBlockPosition(id, position);
  }

  void updateImageBlockOcrTextOnPage(int pageIndex, String id, String text) {
    _ensurePageSelected(pageIndex);
    updateImageBlockOcrText(id, text);
  }

  void addInkStrokeOnPage(
    int pageIndex,
    List<InkPoint> points, {
    double? widthOverride,
    DrawingTool? toolOverride,
  }) {
    _ensurePageSelected(pageIndex);
    addInkStroke(
      points,
      widthOverride: widthOverride,
      toolOverride: toolOverride,
    );
  }

  void eraseInkStrokesByIdOnPage(int pageIndex, Set<String> ids) {
    _ensurePageSelected(pageIndex);
    eraseInkStrokesById(ids);
  }

  void commitImageMoveOnPage(
    int pageIndex,
    String id,
    Offset start,
    Offset end,
  ) {
    _ensurePageSelected(pageIndex);
    commitImageMove(id, start, end);
  }

  void setTool(DrawingTool newTool) {
    tool = newTool;
    if (newTool.isEraser) {
      lastEraserTool = newTool;
    }
    if (newTool.isShape) {
      lastShapeTool = newTool;
    }
    if (tool != DrawingTool.text) {
      clearActiveTextBlock();
    }
    notifyListeners();
  }

  void setActiveTextBlock(String? blockId, quill.QuillController? controller) {
    activeTextBlockId = blockId;
    activeTextController = controller;
    notifyListeners();
  }

  void clearActiveTextBlock() {
    activeTextBlockId = null;
    activeTextController = null;
    notifyListeners();
  }

  void markTextTap() {
    _suppressBackgroundTap = true;
  }

  bool consumeBackgroundTapSuppression() {
    final value = _suppressBackgroundTap;
    _suppressBackgroundTap = false;
    return value;
  }

  void setColor(Color newColor) {
    inkColor = newColor;
    _addRecentColor(newColor);
    _schedulePrefsSave();
    notifyListeners();
  }

  void setLastTextFontFamily(String? family) {
    lastTextFontFamily = family;
    _schedulePrefsSave();
  }

  void setLastTextFontSize(double size) {
    lastTextFontSize = size;
    _schedulePrefsSave();
  }

  void setLastTextColor(Color color) {
    lastTextColor = color;
    _addRecentColor(color);
    _schedulePrefsSave();
  }

  void setStrokeWidth(double value) {
    inkStrokeWidth = value;
    notifyListeners();
  }

  void setQuickColor(int index, Color newColor) {
    if (index < 0 || index >= quickColors.length) {
      return;
    }
    quickColors[index] = newColor;
    setColor(newColor);
    _schedulePrefsSave();
  }

  void _addRecentColor(Color color) {
    recentColors.removeWhere((item) => item.toARGB32() == color.toARGB32());
    recentColors.insert(0, color);
    if (recentColors.length > 12) {
      recentColors.removeRange(12, recentColors.length);
    }
  }

  Future<void> _loadEditorPrefs() async {
    try {
      final file = await _prefsFile();
      if (!await file.exists()) {
        return;
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final inkHex = decoded['inkColor']?.toString();
      final lastTextHex = decoded['lastTextColor']?.toString();
      final lastFont = decoded['lastTextFontFamily']?.toString();
      final lastSize = decoded['lastTextFontSize'];
      final quick = decoded['quickColors'];
      final recent = decoded['recentColors'];

      final inkParsed = _colorFromHex(inkHex);
      if (inkParsed != null) {
        inkColor = inkParsed;
      }
      final textParsed = _colorFromHex(lastTextHex);
      if (textParsed != null) {
        lastTextColor = textParsed;
      }
      if (lastFont != null && lastFont.isNotEmpty) {
        lastTextFontFamily = lastFont;
      }
      final sizeParsed = lastSize is num ? lastSize.toDouble() : null;
      if (sizeParsed != null) {
        lastTextFontSize = sizeParsed;
      }
      if (quick is List) {
        final mapped = quick
            .map((item) => _colorFromHex(item?.toString()))
            .whereType<Color>()
            .toList();
        if (mapped.isNotEmpty) {
          quickColors
            ..clear()
            ..addAll(mapped);
        }
      }
      if (recent is List) {
        final mapped = recent
            .map((item) => _colorFromHex(item?.toString()))
            .whereType<Color>()
            .toList();
        if (mapped.isNotEmpty) {
          recentColors
            ..clear()
            ..addAll(mapped);
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  void _schedulePrefsSave() {
    _prefsSaveDebounce?.cancel();
    _prefsSaveDebounce = Timer(const Duration(milliseconds: 250), () {
      _saveEditorPrefs();
    });
  }

  Future<void> _saveEditorPrefs() async {
    try {
      final file = await _prefsFile();
      final payload = <String, dynamic>{
        'inkColor': _colorToHex(inkColor),
        'quickColors': quickColors.map(_colorToHex).toList(),
        'recentColors': recentColors.map(_colorToHex).toList(),
        'lastTextColor': _colorToHex(lastTextColor),
        'lastTextFontFamily': lastTextFontFamily,
        'lastTextFontSize': lastTextFontSize,
      };
      await file.writeAsString(jsonEncode(payload));
    } catch (_) {}
  }

  Future<File> _prefsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/editor_prefs.json');
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

  Future<String?> handleTap(Offset point) async {
    if (tool == DrawingTool.text) {
      addTextBlock(point);
      return null;
    }
    if (tool == DrawingTool.image) {
      return addImageBlock(point);
    }
    return null;
  }

  void undo() {
    if (_undoActions.isEmpty) {
      return;
    }
    final action = _undoActions.removeLast();
    final updated = action.revert(currentPage);
    _redoActions.add(action);
    _updatePage(updated);
    _save();
  }

  void redo() {
    if (_redoActions.isEmpty) {
      return;
    }
    final action = _redoActions.removeLast();
    final updated = action.apply(currentPage);
    _undoActions.add(action);
    _updatePage(updated);
    _save();
  }

  void addPage() {
    final nextIndex = pages.length + 1;
    final page = NotePage(
      id: _uuid.v4(),
      title: 'Page $nextIndex',
      textBlocks: <TextBlock>[],
      imageBlocks: <ImageBlock>[],
      inkStrokes: <InkStroke>[],
      isBookmarked: false,
    );
    pages = [...pages, page];
    currentPageIndex = pages.length - 1;
    activeTextBlockId = null;
    activeTextController = null;
    _save();
    notifyListeners();
  }

  void setCurrentPage(int index) {
    if (index < 0 || index >= pages.length) {
      return;
    }
    if (currentPageIndex == index) {
      return;
    }
    activeTextBlockId = null;
    activeTextController = null;
    currentPageIndex = index;
    notifyListeners();
  }

  void toggleBookmark() {
    final page = currentPage.copyWith(isBookmarked: !currentPage.isBookmarked);
    _updatePage(page);
    _save();
  }

  void addTextBlock(Offset position) {
    final baseSize = lastTextFontSize;
    final baseColor = lastTextColor;
    final delta = quill_delta.Delta()
      ..insert('Text', <String, dynamic>{
        'size': baseSize.toInt().toString(),
        'color': _colorToHex(baseColor),
        if (lastTextFontFamily != null) 'font': lastTextFontFamily,
      })
      ..insert('\n');
    final doc = quill.Document.fromDelta(delta);
    final block = TextBlock(
      id: _uuid.v4(),
      text: 'Text',
      deltaJson: jsonEncode(doc.toDelta().toJson()),
      position: position,
      fontSize: baseSize,
      color: baseColor,
      width: 240,
    );
    _applyAction(AddTextAction(block));
    setActiveTextBlock(block.id, null);
    _save();
  }

  void updateTextBlockContent(
    TextBlock before, {
    required String plainText,
    required String deltaJson,
  }) {
    final normalizedText = plainText.trimRight();
    final after = before.copyWith(text: normalizedText, deltaJson: deltaJson);
    _applyAction(UpdateTextAction(before: before, after: after));
    _save();
  }

  void updateTextBlockPosition(String id, Offset position) {
    final updated = currentPage.textBlocks
        .map((item) => item.id == id ? item.copyWith(position: position) : item)
        .toList();
    _updatePage(currentPage.copyWith(textBlocks: updated));
  }

  void deleteTextBlock(String id) {
    final block = currentPage.textBlocks.firstWhere((item) => item.id == id);
    _applyAction(DeleteTextAction(block));
    clearActiveTextBlock();
    _save();
  }

  void commitTextMove(String id, Offset start, Offset end) {
    if (start == end) {
      return;
    }
    _applyAction(
      MoveTextAction(
        id: id,
        from: OffsetPosition.fromOffset(start),
        to: OffsetPosition.fromOffset(end),
      ),
    );
    _save();
  }

  Future<String?> addImageBlock(Offset position) async {
    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null) {
      return null;
    }
    final file = await _persistImage(picked);
    final size = await _imageSize(file);
    final targetWidth = 240.0;
    final ratio = size.width == 0 ? 1.0 : size.height / size.width;
    final targetHeight = targetWidth * ratio;
    final block = ImageBlock(
      id: _uuid.v4(),
      path: file.path,
      ocrText: '',
      position: position,
      width: targetWidth,
      height: targetHeight.clamp(80, 320).toDouble(),
    );
    _applyAction(AddImageAction(block));
    _save();

    final ocrText = await _runOcr(file);
    if (ocrText == null) {
      return 'OCR is not supported on this platform.';
    }
    if (ocrText.trim().isNotEmpty) {
      updateImageBlockOcrText(block.id, ocrText.trim());
    }
    return null;
  }

  Future<String?> runOcrForImage(ImageBlock block) async {
    final file = File(block.path);
    if (!await file.exists()) {
      return 'Image file not found.';
    }
    final ocrText = await _runOcr(file);
    if (ocrText == null) {
      return 'OCR is not supported on this platform.';
    }
    updateImageBlockOcrText(block.id, ocrText.trim());
    return null;
  }

  void updateImageBlockPosition(String id, Offset position) {
    final updated = currentPage.imageBlocks
        .map((item) => item.id == id ? item.copyWith(position: position) : item)
        .toList();
    _updatePage(currentPage.copyWith(imageBlocks: updated));
  }

  void updateImageBlockOcrText(String id, String text) {
    final before = currentPage.imageBlocks.map((item) => item).toList();
    final updated = currentPage.imageBlocks
        .map((item) => item.id == id ? item.copyWith(ocrText: text) : item)
        .toList();
    _applyAction(UpdateImageOcrAction(id: id, ocrText: text, before: before));
    _updatePage(currentPage.copyWith(imageBlocks: updated));
    _save();
  }

  void addInkStroke(
    List<InkPoint> points, {
    double? widthOverride,
    DrawingTool? toolOverride,
  }) {
    if (points.isEmpty) {
      return;
    }
    final strokeTool = toolOverride ?? tool;
    final baseWidth = strokeTool == DrawingTool.highlighter
        ? inkStrokeWidth * 8.0
        : inkStrokeWidth;
    final stroke = InkStroke(
      id: _uuid.v4(),
      points: points,
      color: inkColor,
      width: widthOverride ?? baseWidth,
      tool: strokeTool,
    );
    _applyAction(AddInkStrokeAction(stroke));
    _save();
  }

  void eraseInkStrokesById(Set<String> ids) {
    if (ids.isEmpty) {
      return;
    }
    final before = List<InkStroke>.from(currentPage.inkStrokes);
    final after = before.where((item) => !ids.contains(item.id)).toList();
    if (after.length == before.length) {
      return;
    }
    _applyAction(RemoveInkStrokesAction(before: before, after: after));
    _save();
  }

  void commitImageMove(String id, Offset start, Offset end) {
    if (start == end) {
      return;
    }
    _applyAction(
      MoveImageAction(
        id: id,
        from: OffsetPosition.fromOffset(start),
        to: OffsetPosition.fromOffset(end),
      ),
    );
    _save();
  }

  Future<File> _persistImage(XFile picked) async {
    final dir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory('${dir.path}/images');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = picked.path.split('.').last;
    final target = File('${imagesDir.path}/img_$timestamp.$extension');
    return File(picked.path).copy(target.path);
  }

  String _colorToHex(Color color) {
    final value = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${value.substring(2)}';
  }

  Future<Size> _imageSize(File file) async {
    final bytes = await file.readAsBytes();
    final codec = await instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    return Size(image.width.toDouble(), image.height.toDouble());
  }

  Future<String?> _runOcr(File file) async {
    if (!_isOcrSupported()) {
      return null;
    }
    final input = mlkit.InputImage.fromFilePath(file.path);
    final recognizer = mlkit.TextRecognizer(
      script: mlkit.TextRecognitionScript.latin,
    );
    try {
      final result = await recognizer.processImage(input);
      return result.text;
    } finally {
      await recognizer.close();
    }
  }

  bool _isOcrSupported() {
    if (kIsWeb) {
      return false;
    }
    return Platform.isAndroid || Platform.isIOS;
  }

  Rect _computeContentBounds() {
    Rect? bounds;

    for (final stroke in currentPage.inkStrokes) {
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
      final rect = Rect.fromLTRB(
        minX - extra,
        minY - extra,
        maxX + extra,
        maxY + extra,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    for (final block in currentPage.textBlocks) {
      final estimatedHeight = math.max(44.0, block.fontSize * 2.8);
      final rect = Rect.fromLTWH(
        block.position.dx,
        block.position.dy,
        block.width,
        estimatedHeight,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    for (final block in currentPage.imageBlocks) {
      final rect = Rect.fromLTWH(
        block.position.dx,
        block.position.dy,
        block.width,
        block.height,
      );
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }

    return bounds ?? const Rect.fromLTWH(-600, -600, 1200, 1200);
  }

  void _applyAction(EditorAction action) {
    final updated = action.apply(currentPage);
    _undoActions.add(action);
    _redoActions.clear();
    _updatePage(updated);
  }

  void _updatePage(NotePage page) {
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == currentPageIndex) page else pages[i],
    ];
    notifyListeners();
  }

  Future<void> _save() async {
    final updated = notebook.copyWith(pages: pages, updatedAt: DateTime.now());
    await repository.saveNotebook(updated);
  }
}
