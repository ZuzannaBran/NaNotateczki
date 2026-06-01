import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart' as quill_delta;
import 'package:file_picker/file_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:uuid/uuid.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/ink_stroke.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/text_block.dart';
import 'editor_actions.dart';

class LassoSelection {
  LassoSelection({
    required this.pageIndex,
    required this.bounds,
    required this.strokeIds,
    required this.textBlockIds,
    required this.imageBlockIds,
    this.delta = Offset.zero,
  });

  final int pageIndex;
  final Rect bounds;
  final List<String> strokeIds;
  final List<String> textBlockIds;
  final List<String> imageBlockIds;
  final Offset delta;

  LassoSelection copyWith({Offset? delta, Rect? bounds}) {
    return LassoSelection(
      pageIndex: pageIndex,
      bounds: bounds ?? this.bounds,
      strokeIds: strokeIds,
      textBlockIds: textBlockIds,
      imageBlockIds: imageBlockIds,
      delta: delta ?? this.delta,
    );
  }

  bool get isEmpty =>
      strokeIds.isEmpty && textBlockIds.isEmpty && imageBlockIds.isEmpty;
}

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
  String? activeImageBlockId;
  LassoSelection? lassoSelection;
  final ValueNotifier<Offset> lassoDragDelta = ValueNotifier(Offset.zero);
  _ElementClipboardItem? _elementClipboard;
  bool _suppressBackgroundTap = false;
  double viewScale = 1.0;
  Offset viewPan = Offset.zero;
  double _pageWidth = 0.0;
  double _pageHeight = 0.0;
  double _pageGap = 0.0;

  NotePage get currentPage => pages[currentPageIndex];

  bool get canUndo => _undoActions.isNotEmpty;
  bool get canRedo => _redoActions.isNotEmpty;
  Rect get contentBounds => _computeContentBounds();
  Size get layoutPageSize => Size(_pageWidth, _pageHeight);

  void updatePageLayout({
    required double pageWidth,
    required double pageHeight,
    required double pageGap,
  }) {
    if (_pageWidth == pageWidth &&
        _pageHeight == pageHeight &&
        _pageGap == pageGap) {
      return;
    }
    _pageWidth = pageWidth;
    _pageHeight = pageHeight;
    _pageGap = pageGap;
  }

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

  double get _pageExtent => _pageHeight + _pageGap;

  Offset _pageOriginForIndex(int index) {
    if (_pageExtent <= 0) {
      return Offset.zero;
    }
    return Offset(0, _pageExtent * index);
  }

  int _pageIndexForPosition(Offset position) {
    if (pages.isEmpty) {
      return 0;
    }
    if (_pageExtent <= 0) {
      return currentPageIndex;
    }
    final raw = (position.dy / _pageExtent).floor();
    return raw.clamp(0, pages.length - 1);
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

  int? _pageIndexContainingTextBlock(String id) {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].textBlocks.any((item) => item.id == id)) {
        return i;
      }
    }
    return null;
  }

  int? _pageIndexContainingImageBlock(String id) {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].imageBlocks.any((item) => item.id == id)) {
        return i;
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

  void updateImageBlockOnPage(int pageIndex, ImageBlock block) {
    _ensurePageSelected(pageIndex);
    final updated = currentPage.imageBlocks
        .map((item) => item.id == block.id ? block : item)
        .toList();
    _updatePage(currentPage.copyWith(imageBlocks: updated));
  }

  void updateImageBlockOcrTextOnPage(int pageIndex, String id, String text) {
    _ensurePageSelected(pageIndex);
    updateImageBlockOcrText(id, text);
  }

  void deleteImageBlockOnPage(int pageIndex, String id) {
    _ensurePageSelected(pageIndex);
    deleteImageBlock(id);
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

  void finalizeImageMoveOnPage(
    int pageIndex,
    String id,
    Offset start,
    Offset end,
  ) {
    if (start == end) {
      return;
    }
    final targetIndex = _pageIndexForPosition(end);
    if (targetIndex == pageIndex || _pageExtent <= 0) {
      commitImageMoveOnPage(pageIndex, id, start, end);
      return;
    }
    _moveImageBlockToPage(pageIndex, targetIndex, id, end);
  }

  void commitImageResizeOnPage(
    int pageIndex,
    ImageBlock before,
    ImageBlock after,
  ) {
    _ensurePageSelected(pageIndex);
    commitImageResize(before, after);
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
    lassoSelection = null;
    notifyListeners();
  }

  void setActiveTextBlock(String? blockId, quill.QuillController? controller) {
    activeTextBlockId = blockId;
    activeTextController = controller;
    activeImageBlockId = null;
    notifyListeners();
  }

  void clearActiveTextBlock() {
    activeTextBlockId = null;
    activeTextController = null;
    notifyListeners();
  }

  void setActiveImageBlock(String? blockId) {
    activeImageBlockId = blockId;
    if (blockId != null) {
      activeTextBlockId = null;
      activeTextController = null;
    }
    notifyListeners();
  }

  void clearLassoSelection() {
    if (lassoSelection != null) {
      lassoSelection = null;
      lassoDragDelta.value = Offset.zero;
      notifyListeners();
    }
  }

  void selectWithLasso(List<Offset> points, int pageIndex) {
    if (points.length < 3) {
      clearLassoSelection();
      return;
    }

    _ensurePageSelected(pageIndex);
    final page = pages[pageIndex];
    final pageOrigin = _pageOriginForIndex(pageIndex);
    final documentPoints = points.map((point) => point + pageOrigin).toList();
    final selectedStrokes = <String>[];
    final selectedTextBlocks = <String>[];
    final selectedImages = <String>[];

    bool isInsidePath(Offset point, List<Offset> path) {
      var inside = false;
      for (var i = 0, j = path.length - 1; i < path.length; j = i++) {
        final xi = path[i].dx, yi = path[i].dy;
        final xj = path[j].dx, yj = path[j].dy;
        final intersect =
            ((yi > point.dy) != (yj > point.dy)) &&
            (point.dx < (xj - xi) * (point.dy - yi) / (yj - yi) + xi);
        if (intersect) inside = !inside;
      }
      return inside;
    }

    bool isInsidePagePath(Offset point) => isInsidePath(point, points);
    bool isInsideDocumentPath(Offset point) {
      return isInsidePath(point, documentPoints);
    }

    bool rectTouchesDocumentPath(Rect rect) {
      final pointsToTest = [
        rect.center,
        rect.topLeft,
        rect.topRight,
        rect.bottomLeft,
        rect.bottomRight,
      ];
      return pointsToTest.any(isInsideDocumentPath);
    }

    for (final s in page.inkStrokes) {
      if (s.points.any((p) => isInsidePagePath(Offset(p.dx, p.dy)))) {
        selectedStrokes.add(s.id);
      }
    }

    for (final t in page.textBlocks) {
      final estimatedHeight = math.max(44.0, t.fontSize * 2.8);
      final rect = Rect.fromLTWH(
        t.position.dx,
        t.position.dy,
        t.width,
        estimatedHeight,
      );
      if (rectTouchesDocumentPath(rect)) selectedTextBlocks.add(t.id);
    }

    for (final i in page.imageBlocks) {
      final rect = Rect.fromLTWH(
        i.position.dx,
        i.position.dy,
        i.width,
        i.height,
      );
      if (rectTouchesDocumentPath(rect)) selectedImages.add(i.id);
    }

    if (selectedStrokes.isEmpty &&
        selectedTextBlocks.isEmpty &&
        selectedImages.isEmpty) {
      clearLassoSelection();
      return;
    }

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in documentPoints) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }

    lassoSelection = LassoSelection(
      pageIndex: pageIndex,
      bounds: Rect.fromLTRB(minX, minY, maxX, maxY),
      strokeIds: selectedStrokes,
      textBlockIds: selectedTextBlocks,
      imageBlockIds: selectedImages,
    );
    lassoDragDelta.value = Offset.zero;

    activeTextBlockId = null;
    activeImageBlockId = null;
    notifyListeners();
  }

  void updateLassoMove(Offset delta) {
    if (lassoSelection == null) return;
    lassoDragDelta.value = delta;
  }

  void commitLassoMove() {
    final sel = lassoSelection;
    final delta = lassoDragDelta.value;
    if (sel == null || delta == Offset.zero) return;
    _ensurePageSelected(sel.pageIndex);

    final action = MoveSelectionAction(
      strokeIds: sel.strokeIds,
      textBlockIds: sel.textBlockIds,
      imageBlockIds: sel.imageBlockIds,
      delta: OffsetPosition.fromOffset(delta),
    );

    _applyActionWithoutNotify(action);

    lassoSelection = sel.copyWith(
      bounds: sel.bounds.shift(delta),
      delta: Offset.zero,
    );
    lassoDragDelta.value = Offset.zero;
    notifyListeners();
    _save();
  }

  void deleteLassoSelection() {
    final sel = lassoSelection;
    if (sel == null) return;
    _ensurePageSelected(sel.pageIndex);

    final page = pages[sel.pageIndex];
    final strokes = page.inkStrokes
        .where((s) => sel.strokeIds.contains(s.id))
        .toList();
    final texts = page.textBlocks
        .where((t) => sel.textBlockIds.contains(t.id))
        .toList();
    final images = page.imageBlocks
        .where((i) => sel.imageBlockIds.contains(i.id))
        .toList();

    if (strokes.isEmpty && texts.isEmpty && images.isEmpty) return;

    final action = DeleteSelectionAction(
      deletedStrokes: strokes,
      deletedTextBlocks: texts,
      deletedImageBlocks: images,
    );
    _applyAction(action);
    clearLassoSelection();
    _save();
  }

  void clearActiveImageBlock() {
    activeImageBlockId = null;
    notifyListeners();
  }

  ImageBlock? _activeImageGestureBefore;

  bool get isPinchToScaleImageActive => _activeImageGestureBefore != null;

  void startPinchToScaleActiveImage() {
    final activeId = activeImageBlockId;
    if (activeId != null) {
      _activeImageGestureBefore = findImageBlockById(activeId);
    } else {
      _activeImageGestureBefore = null;
    }
  }

  void updatePinchToScaleActiveImage(double scaleDelta, Offset panDeltaWorld) {
    if (_activeImageGestureBefore == null) return;
    final activeId = activeImageBlockId;
    if (activeId == null) return;

    final currentBlock = findImageBlockById(activeId);
    if (currentBlock == null) return;

    final pageIndex = _pageIndexContainingImageBlock(activeId);
    if (pageIndex == null) return;

    final newWidth = currentBlock.width * scaleDelta;
    final newHeight = currentBlock.height * scaleDelta;
    final center = Offset(
      currentBlock.position.dx + currentBlock.width / 2,
      currentBlock.position.dy + currentBlock.height / 2,
    );
    final newCenter = center + panDeltaWorld;
    final newPosition = newCenter - Offset(newWidth / 2, newHeight / 2);

    final updatedBlock = currentBlock.copyWith(
      position: newPosition,
      width: newWidth,
      height: newHeight,
    );

    updateImageBlockOnPage(pageIndex, updatedBlock);
  }

  void endPinchToScaleActiveImage() {
    final before = _activeImageGestureBefore;
    _activeImageGestureBefore = null;

    if (before == null) return;
    final activeId = activeImageBlockId;
    if (activeId == null) return;

    final after = findImageBlockById(activeId);
    if (after == null) return;

    if (before.width != after.width ||
        before.height != after.height ||
        before.position != after.position) {
      final pageIndex = _pageIndexContainingImageBlock(activeId);
      if (pageIndex != null) {
        commitImageResizeOnPage(pageIndex, before, after);
      }
    }
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
    } catch (e) {
      debugPrint('EditorController._loadEditorPrefs failed: $e');
    }
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
    } catch (e) {
      debugPrint('EditorController._saveEditorPrefs failed: $e');
    }
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
    final page = _createPage(nextIndex);
    pages = [...pages, page];
    currentPageIndex = pages.length - 1;
    activeTextBlockId = null;
    activeTextController = null;
    activeImageBlockId = null;
    _save();
    notifyListeners();
  }

  NotePage _createPage(int index) {
    return NotePage(
      id: _uuid.v4(),
      title: 'Page $index',
      textBlocks: <TextBlock>[],
      imageBlocks: <ImageBlock>[],
      inkStrokes: <InkStroke>[],
      isBookmarked: false,
    );
  }

  void _ensurePageCount(List<NotePage> working, int count) {
    while (working.length < count) {
      working.add(_createPage(working.length + 1));
    }
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
    activeImageBlockId = null;
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
    setTool(DrawingTool.text);
    setActiveTextBlock(block.id, null);
    _save();
  }

  void addTextBlockFromText(Offset position, String text) {
    final baseSize = lastTextFontSize;
    final baseColor = lastTextColor;
    final normalized = text.trimRight();
    final delta = quill_delta.Delta();
    if (normalized.isNotEmpty) {
      delta.insert(normalized, <String, dynamic>{
        'size': baseSize.toInt().toString(),
        'color': _colorToHex(baseColor),
        if (lastTextFontFamily != null) 'font': lastTextFontFamily,
      });
    }
    delta.insert('\n');
    final doc = quill.Document.fromDelta(delta);
    final block = TextBlock(
      id: _uuid.v4(),
      text: normalized,
      deltaJson: jsonEncode(doc.toDelta().toJson()),
      position: position,
      fontSize: baseSize,
      color: baseColor,
      width: 260,
    );
    _applyAction(AddTextAction(block));
    setTool(DrawingTool.text);
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

  void updateTextBlockWidth(String id, double width) {
    final updated = currentPage.textBlocks
        .map((item) => item.id == id ? item.copyWith(width: width) : item)
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

  void commitTextResize(TextBlock before, TextBlock after) {
    if (before.width == after.width) {
      return;
    }
    _applyAction(UpdateTextAction(before: before, after: after));
    _save();
  }

  Future<String?> addImageBlock(Offset position) async {
    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null) {
      return null;
    }
    final file = await _persistImage(picked);
    return _addImageBlockFromFile(file, position);
  }

  Future<String?> insertFromFilePicker(Offset position) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'pdf', 'txt'],
      );
    } catch (e) {
      debugPrint('EditorController.insertFromFilePicker: picker failed: $e');
      if (Platform.isLinux) {
        return 'Missing "zenity". Install it: sudo apt-get install zenity.';
      }
      return 'File picker failed to open.';
    }
    if (result == null) {
      return null;
    }
    final path = result.files.single.path;
    if (path == null || path.isEmpty) {
      return 'Selected file is not accessible.';
    }
    try {
      return await _insertFile(File(path), position);
    } on PlatformNotSupportedException {
      return 'PDF rendering is not supported on this platform.';
    } on MissingPluginException {
      return 'PDF renderer plugin is missing for this platform.';
    } catch (e) {
      debugPrint('EditorController.insertFromFilePicker: insert failed: $e');
      return 'Failed to insert file.';
    }
  }

  Future<String?> insertFromClipboard(Offset position) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard != null) {
      final reader = await clipboard.read();
      final imageInserted = await _tryInsertImageFromClipboard(
        reader,
        position,
      );
      if (imageInserted) {
        return null;
      }
      final text = await _readTextFromClipboard(reader);
      if (text != null && text.trim().isNotEmpty) {
        addTextBlockFromText(position, text);
        return null;
      }
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final fallbackText = data?.text;
    if (fallbackText == null || fallbackText.trim().isEmpty) {
      return 'Clipboard is empty. Use Attach file for images or PDFs.';
    }
    addTextBlockFromText(position, fallbackText);
    return null;
  }

  Future<String?> pasteElementOrClipboard(Offset position) async {
    final clipboardItem = _elementClipboard;
    if (clipboardItem == null) {
      return insertFromClipboard(position);
    }

    switch (clipboardItem) {
      case _TextElementClipboardItem(:final block):
        final pasted = block.copyWith(id: _uuid.v4(), position: position);
        _applyAction(AddTextAction(pasted));
        setTool(DrawingTool.text);
        setActiveTextBlock(pasted.id, null);
        _save();
        return null;
      case _ImageElementClipboardItem(:final block):
        final pasted = block.copyWith(id: _uuid.v4(), position: position);
        _applyAction(AddImageAction(pasted));
        _activateInsertedImage(pasted.id);
        _save();
        return null;
      case _LassoElementClipboardItem(
        :final strokes,
        :final textBlocks,
        :final imageBlocks,
        :final bounds,
        :final pageIndex,
      ):
        final targetPageIndex = _pageIndexForPosition(position);
        _ensurePageSelected(targetPageIndex);
        final delta = position - bounds.topLeft;
        final sourceOrigin = _pageOriginForIndex(pageIndex);
        final targetOrigin = _pageOriginForIndex(targetPageIndex);
        final newStrokes = strokes
            .map(
              (s) => s.copyWith(
                id: _uuid.v4(),
                points: s.points
                    .map(
                      (p) => InkPoint(
                        dx: p.dx + sourceOrigin.dx + delta.dx - targetOrigin.dx,
                        dy: p.dy + sourceOrigin.dy + delta.dy - targetOrigin.dy,
                        pressure: p.pressure,
                      ),
                    )
                    .toList(),
              ),
            )
            .toList();
        final newTextBlocks = textBlocks
            .map(
              (t) => t.copyWith(id: _uuid.v4(), position: t.position + delta),
            )
            .toList();
        final newImageBlocks = imageBlocks
            .map(
              (i) => i.copyWith(id: _uuid.v4(), position: i.position + delta),
            )
            .toList();

        _applyAction(
          PasteSelectionAction(
            strokes: newStrokes,
            textBlocks: newTextBlocks,
            imageBlocks: newImageBlocks,
          ),
        );

        lassoSelection = LassoSelection(
          pageIndex: targetPageIndex,
          bounds: bounds.shift(delta),
          strokeIds: newStrokes.map((s) => s.id).toList(),
          textBlockIds: newTextBlocks.map((t) => t.id).toList(),
          imageBlockIds: newImageBlocks.map((i) => i.id).toList(),
        );
        lassoDragDelta.value = Offset.zero;
        _save();
        return null;
    }
  }

  Future<String?> copyActiveElementToClipboard() async {
    final sel = lassoSelection;
    if (sel != null && !sel.isEmpty) {
      final page = pages[sel.pageIndex];
      final strokes = page.inkStrokes
          .where((s) => sel.strokeIds.contains(s.id))
          .toList();
      final texts = page.textBlocks
          .where((t) => sel.textBlockIds.contains(t.id))
          .toList();
      final images = page.imageBlocks
          .where((i) => sel.imageBlockIds.contains(i.id))
          .toList();

      _elementClipboard = _LassoElementClipboardItem(
        strokes: strokes,
        textBlocks: texts,
        imageBlocks: images,
        bounds: sel.bounds.shift(sel.delta),
        pageIndex: sel.pageIndex,
      );
      return null;
    }

    final textId = activeTextBlockId;
    if (textId != null) {
      final block = findTextBlockById(textId);
      if (block == null) {
        return 'Selected text is no longer available.';
      }
      _elementClipboard = _TextElementClipboardItem(block);
      await Clipboard.setData(ClipboardData(text: block.text));
      return null;
    }

    final imageId = activeImageBlockId;
    if (imageId != null) {
      final block = findImageBlockById(imageId);
      if (block == null) {
        return 'Selected image is no longer available.';
      }
      _elementClipboard = _ImageElementClipboardItem(block);
      final imageMessage = await copyActiveImageToClipboard();
      if (imageMessage == 'Image file not found.') {
        return imageMessage;
      }
      return null;
    }

    return 'Select text or image to copy.';
  }

  Future<String?> cutActiveElementToClipboard() async {
    final message = await copyActiveElementToClipboard();
    if (message != null) {
      return message;
    }
    deleteActiveElement();
    return null;
  }

  void deleteActiveElement() {
    final sel = lassoSelection;
    if (sel != null && !sel.isEmpty) {
      deleteLassoSelection();
      return;
    }

    final textId = activeTextBlockId;
    if (textId != null) {
      final pageIndex = _pageIndexContainingTextBlock(textId);
      if (pageIndex != null) {
        deleteTextBlockOnPage(pageIndex, textId);
      }
      return;
    }

    final imageId = activeImageBlockId;
    if (imageId != null) {
      final pageIndex = _pageIndexContainingImageBlock(imageId);
      if (pageIndex != null) {
        deleteImageBlockOnPage(pageIndex, imageId);
      }
    }
  }

  Future<String?> copyActiveImageToClipboard() async {
    final id = activeImageBlockId;
    if (id == null) {
      return 'Select an image to copy.';
    }
    final block = findImageBlockById(id);
    if (block == null) {
      return 'Selected image is no longer available.';
    }
    final file = File(block.path);
    if (!await file.exists()) {
      return 'Image file not found.';
    }
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      return 'Clipboard is not available.';
    }
    final bytes = await file.readAsBytes();
    final item = DataWriterItem();
    final lower = block.path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      item.add(Formats.jpeg(bytes));
    } else {
      item.add(Formats.png(bytes));
    }
    await clipboard.write([item]);
    return null;
  }

  Future<bool> _tryInsertImageFromClipboard(
    ClipboardReader reader,
    Offset position,
  ) async {
    final pngBytes = await _readClipboardImageBytes(reader, Formats.png);
    if (pngBytes != null && pngBytes.isNotEmpty) {
      await _addImageBlockFromBytes(pngBytes, position, 'png');
      return true;
    }
    final jpegBytes = await _readClipboardImageBytes(reader, Formats.jpeg);
    if (jpegBytes != null && jpegBytes.isNotEmpty) {
      await _addImageBlockFromBytes(jpegBytes, position, 'jpg');
      return true;
    }
    return false;
  }

  Future<String?> _readTextFromClipboard(ClipboardReader reader) async {
    if (!reader.canProvide(Formats.plainText)) {
      return null;
    }
    final text = await reader.readValue(Formats.plainText);
    return text is String ? text : null;
  }

  Future<Uint8List?> _readClipboardImageBytes(
    ClipboardReader reader,
    SimpleFileFormat format,
  ) async {
    if (!reader.canProvide(format)) {
      return null;
    }
    final completer = Completer<Uint8List?>();
    reader.getFile(format, (file) async {
      try {
        final bytes = await _readStreamBytes(file.getStream());
        if (!completer.isCompleted) {
          completer.complete(bytes);
        }
      } catch (e) {
        debugPrint('EditorController._readClipboardImageBytes failed: $e');
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      }
    });
    return completer.future;
  }

  Future<Uint8List> _readStreamBytes(Stream<Uint8List> stream) async {
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  Size _initialImageBlockSize(Size sourceSize) {
    final sourceWidth = sourceSize.width > 0 ? sourceSize.width : 1.0;
    final sourceHeight = sourceSize.height > 0 ? sourceSize.height : 1.0;
    final sourceAspect = sourceWidth / sourceHeight;
    final maxWidth = notebook.kind == NotebookKind.notebook
        ? (_pageWidth > 0 ? _pageWidth : 260.0)
        : 360.0;
    final maxHeight = notebook.kind == NotebookKind.notebook
        ? (_pageHeight > 0 ? _pageHeight : 420.0)
        : 520.0;
    final pageAspect = maxWidth / maxHeight;
    if (!sourceAspect.isFinite || sourceAspect <= 0 || !pageAspect.isFinite) {
      return const Size(260, 260);
    }
    if (sourceAspect >= pageAspect) {
      return Size(maxWidth, maxWidth / sourceAspect);
    }
    return Size(maxHeight * sourceAspect, maxHeight);
  }

  Future<String?> _addImageBlockFromBytes(
    Uint8List bytes,
    Offset position,
    String extension,
  ) async {
    final filename = 'clip_${DateTime.now().millisecondsSinceEpoch}.$extension';
    final file = await _persistImageBytes(bytes, filename);
    final size = await _imageSize(file);
    final initialSize = _initialImageBlockSize(size);
    final block = ImageBlock(
      id: _uuid.v4(),
      path: file.path,
      ocrText: '',
      position: position,
      width: initialSize.width,
      height: initialSize.height,
      bytes: bytes,
      imageExt: extension,
      imageMime: 'image/$extension',
    );
    _applyAction(AddImageAction(block));
    _activateInsertedImage(block.id);
    _save();
    return null;
  }

  Future<String?> _insertFile(File file, Offset position) async {
    final path = file.path.toLowerCase();
    if (path.endsWith('.png') ||
        path.endsWith('.jpg') ||
        path.endsWith('.jpeg')) {
      return _addImageBlockFromFile(file, position);
    }
    if (path.endsWith('.pdf')) {
      return _addPdfAsImages(file, position);
    }
    if (path.endsWith('.txt')) {
      final content = await file.readAsString();
      addTextBlockFromText(position, content);
      return null;
    }
    return 'Unsupported file type.';
  }

  Future<String?> _addImageBlockFromFile(
    File file,
    Offset position, {
    bool runOcr = true,
  }) async {
    final persisted = await _persistImageFile(file);
    final bytes = await file.readAsBytes();
    final size = await _imageSize(persisted);
    final initialSize = _initialImageBlockSize(size);
    final extension = file.path.split('.').last.toLowerCase();
    String mime = 'image/jpeg';
    if (extension == 'png') {
      mime = 'image/png';
    } else if (extension == 'gif') {
      mime = 'image/gif';
    } else if (extension == 'webp') {
      mime = 'image/webp';
    }
    final block = ImageBlock(
      id: _uuid.v4(),
      path: persisted.path,
      ocrText: '',
      position: position,
      width: initialSize.width,
      height: initialSize.height,
      bytes: bytes,
      imageExt: extension,
      imageMime: mime,
    );
    _applyAction(AddImageAction(block));
    _activateInsertedImage(block.id);
    _save();
    if (!runOcr) {
      return null;
    }
    final ocrText = await _runOcr(persisted);
    if (ocrText == null) {
      return 'OCR is not supported on this platform.';
    }
    if (ocrText.trim().isNotEmpty) {
      updateImageBlockOcrText(block.id, ocrText.trim());
    }
    return null;
  }

  void _activateInsertedImage(String id) {
    tool = DrawingTool.edit;
    activeImageBlockId = id;
    activeTextBlockId = null;
    activeTextController = null;
    notifyListeners();
  }

  Future<String?> _addPdfAsImages(File pdfFile, Offset position) async {
    if (Platform.isLinux) {
      return _addPdfAsImagesWithPoppler(pdfFile, position);
    }
    try {
      final document = await PdfDocument.openFile(pdfFile.path);
      final pageExtent = _pageExtent;
      final basePageIndex = _pageIndexForPosition(position);
      final localOffset = notebook.kind == NotebookKind.board
          ? position
          : Offset.zero;
      final workingPages = List<NotePage>.from(pages);
      var pageOffset = 0.0;
      for (var pageIndex = 1; pageIndex <= document.pagesCount; pageIndex++) {
        final page = await document.getPage(pageIndex);
        final render = await page.render(
          width: page.width * 2,
          height: page.height * 2,
          format: PdfPageImageFormat.png,
        );
        await page.close();
        if (render == null) {
          continue;
        }
        final file = await _persistImageBytes(
          render.bytes,
          'pdf_${DateTime.now().millisecondsSinceEpoch}_$pageIndex.png',
        );
        final renderWidth = (render.width ?? page.width).toDouble();
        final renderHeight = (render.height ?? page.height).toDouble();
        final size = Size(renderWidth, renderHeight);
        final targetWidth = notebook.kind == NotebookKind.notebook
            ? (_pageWidth > 0 ? _pageWidth : 260.0)
            : 260.0;
        final targetHeight = notebook.kind == NotebookKind.notebook
            ? (_pageHeight > 0 ? _pageHeight : 420.0)
            : targetWidth * (size.width == 0 ? 1.0 : size.height / size.width);
        final targetIndex = notebook.kind == NotebookKind.board
            ? basePageIndex
            : basePageIndex + (pageIndex - 1);
        _ensurePageCount(workingPages, targetIndex + 1);
        final targetOrigin = notebook.kind == NotebookKind.board
            ? Offset.zero
            : (pageExtent <= 0
                  ? Offset.zero
                  : _pageOriginForIndex(targetIndex));
        final targetPosition = notebook.kind == NotebookKind.board
            ? localOffset + Offset(0, pageOffset)
            : targetOrigin + localOffset;
        final block = ImageBlock(
          id: _uuid.v4(),
          path: file.path,
          ocrText: '',
          position: targetPosition,
          width: targetWidth,
          height: notebook.kind == NotebookKind.notebook
              ? targetHeight
              : targetHeight.clamp(80, 520).toDouble(),
          bytes: render.bytes,
          imageExt: 'png',
          imageMime: 'image/png',
        );
        final targetPage = workingPages[targetIndex];
        workingPages[targetIndex] = targetPage.copyWith(
          imageBlocks: [...targetPage.imageBlocks, block],
        );
        if (notebook.kind == NotebookKind.board) {
          pageOffset += block.height + 12;
        }
      }
      await document.close();
      pages = workingPages;
      notifyListeners();
      _save();
      return null;
    } on PlatformNotSupportedException {
      return 'PDF rendering is not supported on this platform.';
    } on MissingPluginException {
      return 'PDF renderer plugin is missing for this platform.';
    } catch (e) {
      debugPrint('EditorController._addPdfAsImages failed: $e');
      return 'Failed to render PDF.';
    }
  }

  Future<String?> _addPdfAsImagesWithPoppler(
    File pdfFile,
    Offset position,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final prefix = '${tempDir.path}/pdf_$stamp';
    final test = await Process.run('pdftoppm', ['-h']);
    if (test.exitCode != 0) {
      return 'Missing "pdftoppm". Install: sudo apt-get install poppler-utils.';
    }
    final result = await Process.run('pdftoppm', [
      '-png',
      '-r',
      '144',
      pdfFile.path,
      prefix,
    ]);
    if (result.exitCode != 0) {
      return 'Failed to render PDF pages.';
    }
    final dir = Directory(tempDir.path);
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (file) =>
                  file.path.startsWith(prefix) && file.path.endsWith('.png'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      return 'No PDF pages were rendered.';
    }
    final pageExtent = _pageExtent;
    final basePageIndex = _pageIndexForPosition(position);
    final localOffset = notebook.kind == NotebookKind.board
        ? position
        : Offset.zero;
    final workingPages = List<NotePage>.from(pages);
    var pageOffset = 0.0;
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final size = await _imageSize(file);
      final targetWidth = notebook.kind == NotebookKind.notebook
          ? (_pageWidth > 0 ? _pageWidth : 260.0)
          : 260.0;
      final targetHeight = notebook.kind == NotebookKind.notebook
          ? (_pageHeight > 0 ? _pageHeight : 420.0)
          : targetWidth * (size.width == 0 ? 1.0 : size.height / size.width);
      final targetIndex = notebook.kind == NotebookKind.board
          ? basePageIndex
          : basePageIndex + i;
      _ensurePageCount(workingPages, targetIndex + 1);
      final targetOrigin = notebook.kind == NotebookKind.board
          ? Offset.zero
          : (pageExtent <= 0 ? Offset.zero : _pageOriginForIndex(targetIndex));
      final targetPosition = notebook.kind == NotebookKind.board
          ? localOffset + Offset(0, pageOffset)
          : targetOrigin + localOffset;
      final block = ImageBlock(
        id: _uuid.v4(),
        path: (await _persistImageFile(file)).path,
        ocrText: '',
        position: targetPosition,
        width: targetWidth,
        height: notebook.kind == NotebookKind.notebook
            ? targetHeight
            : targetHeight.clamp(80, 520).toDouble(),
        bytes: await file.readAsBytes(),
        imageExt: 'png',
        imageMime: 'image/png',
      );
      final targetPage = workingPages[targetIndex];
      workingPages[targetIndex] = targetPage.copyWith(
        imageBlocks: [...targetPage.imageBlocks, block],
      );
      if (notebook.kind == NotebookKind.board) {
        pageOffset += block.height + 12;
      }
    }
    pages = workingPages;
    notifyListeners();
    _save();
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

  void updateImageBlockSize(
    String id, {
    required double width,
    required double height,
  }) {
    final updated = currentPage.imageBlocks
        .map(
          (item) => item.id == id
              ? item.copyWith(width: width, height: height)
              : item,
        )
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

  Future<void> restoreImageCache(int pageIndex, String blockId) async {
    _ensurePageSelected(pageIndex);
    final block = currentPage.imageBlocks
        .where((b) => b.id == blockId)
        .firstOrNull;
    if (block == null || block.bytes == null) return;

    if (block.path.isNotEmpty && File(block.path).existsSync()) return;

    final extension = block.imageExt ?? 'png';
    final filename =
        'restored_${block.id}_${DateTime.now().millisecondsSinceEpoch}.$extension';
    final file = await _persistImageBytes(block.bytes!, filename);

    final updatedBlock = block.copyWith(path: file.path);
    final updated = currentPage.imageBlocks
        .map((item) => item.id == blockId ? updatedBlock : item)
        .toList();
    _updatePage(currentPage.copyWith(imageBlocks: updated));
    _save();
  }

  void deleteImageBlock(String id) {
    final block = currentPage.imageBlocks.firstWhere((item) => item.id == id);
    _applyAction(DeleteImageAction(block));
    clearActiveImageBlock();
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

  void commitImageResize(ImageBlock before, ImageBlock after) {
    if (before.position == after.position &&
        before.width == after.width &&
        before.height == after.height &&
        before.cropLeft == after.cropLeft &&
        before.cropTop == after.cropTop &&
        before.cropRight == after.cropRight &&
        before.cropBottom == after.cropBottom) {
      return;
    }
    _applyAction(UpdateImageAction(before: before, after: after));
    _save();
  }

  void _moveImageBlockToPage(
    int fromPageIndex,
    int toPageIndex,
    String id,
    Offset position,
  ) {
    if (fromPageIndex < 0 || fromPageIndex >= pages.length) {
      return;
    }
    if (toPageIndex < 0 || toPageIndex >= pages.length) {
      return;
    }
    final fromPage = pages[fromPageIndex];
    final blockIndex = fromPage.imageBlocks.indexWhere((item) => item.id == id);
    if (blockIndex == -1) {
      return;
    }
    final moved = fromPage.imageBlocks[blockIndex].copyWith(position: position);
    final updatedFrom = fromPage.copyWith(
      imageBlocks: fromPage.imageBlocks.where((item) => item.id != id).toList(),
    );
    final toPage = pages[toPageIndex];
    final updatedTo = toPage.copyWith(
      imageBlocks: [...toPage.imageBlocks, moved],
    );
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == fromPageIndex)
          updatedFrom
        else if (i == toPageIndex)
          updatedTo
        else
          pages[i],
    ];
    currentPageIndex = toPageIndex;
    activeTextBlockId = null;
    activeTextController = null;
    activeImageBlockId = id;
    notifyListeners();
    _save();
  }

  Future<File> _persistImage(XFile picked) async {
    final dir = await getTemporaryDirectory();
    final imagesDir = Directory('${dir.path}/images_cache');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = picked.path.split('.').last;
    final target = File('${imagesDir.path}/img_$timestamp.$extension');
    return File(picked.path).copy(target.path);
  }

  Future<File> _persistImageFile(File source) async {
    final dir = await getTemporaryDirectory();
    final imagesDir = Directory('${dir.path}/images_cache');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = source.path.split('.').last;
    final target = File('${imagesDir.path}/img_$timestamp.$extension');
    return source.copy(target.path);
  }

  Future<File> _persistImageBytes(Uint8List bytes, String filename) async {
    final dir = await getTemporaryDirectory();
    final imagesDir = Directory('${dir.path}/images_cache');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final target = File('${imagesDir.path}/$filename');
    await target.writeAsBytes(bytes, flush: true);
    return target;
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

  void _applyActionWithoutNotify(EditorAction action) {
    final updated = action.apply(currentPage);
    _undoActions.add(action);
    _redoActions.clear();
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == currentPageIndex) updated else pages[i],
    ];
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

sealed class _ElementClipboardItem {
  const _ElementClipboardItem();
}

class _TextElementClipboardItem extends _ElementClipboardItem {
  const _TextElementClipboardItem(this.block);

  final TextBlock block;
}

class _ImageElementClipboardItem extends _ElementClipboardItem {
  const _ImageElementClipboardItem(this.block);

  final ImageBlock block;
}

class _LassoElementClipboardItem extends _ElementClipboardItem {
  const _LassoElementClipboardItem({
    required this.strokes,
    required this.textBlocks,
    required this.imageBlocks,
    required this.bounds,
    required this.pageIndex,
  });

  final List<InkStroke> strokes;
  final List<TextBlock> textBlocks;
  final List<ImageBlock> imageBlocks;
  final Rect bounds;
  final int pageIndex;
}
