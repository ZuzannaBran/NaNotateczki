import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
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
  EditorController({required this.repository, required this.notebook}) {
    pages = notebook.pages;
    currentPageIndex = 0;
  }

  final NotebookRepository repository;
  final Notebook notebook;
  final Uuid _uuid = const Uuid();
  final ImagePicker _imagePicker = ImagePicker();

  late List<NotePage> pages;
  int currentPageIndex = 0;
  DrawingTool tool = DrawingTool.pen;
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

  NotePage get currentPage => pages[currentPageIndex];

  bool get canUndo => _undoActions.isNotEmpty;
  bool get canRedo => _redoActions.isNotEmpty;

  void setTool(DrawingTool newTool) {
    tool = newTool;
    notifyListeners();
  }

  void setColor(Color newColor) {
    inkColor = newColor;
    _addRecentColor(newColor);
    notifyListeners();
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
  }

  void _addRecentColor(Color color) {
    recentColors.removeWhere((item) => item.value == color.value);
    recentColors.insert(0, color);
    if (recentColors.length > 12) {
      recentColors.removeRange(12, recentColors.length);
    }
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
    _save();
    notifyListeners();
  }

  void setCurrentPage(int index) {
    if (index < 0 || index >= pages.length) {
      return;
    }
    currentPageIndex = index;
    notifyListeners();
  }

  void toggleBookmark() {
    final page = currentPage.copyWith(isBookmarked: !currentPage.isBookmarked);
    _updatePage(page);
    _save();
  }

  void addTextBlock(Offset position) {
    final block = TextBlock(
      id: _uuid.v4(),
      text: 'Text',
      position: position,
      fontSize: 18,
      color: inkColor,
      width: 240,
    );
    _applyAction(AddTextAction(block));
    _save();
  }

  void updateTextBlockText(TextBlock before, String text) {
    final after = before.copyWith(text: text);
    _applyAction(UpdateTextAction(before: before, after: after));
    _save();
  }

  void updateTextBlockPosition(String id, Offset position) {
    final updated = currentPage.textBlocks
        .map((item) => item.id == id ? item.copyWith(position: position) : item)
        .toList();
    _updatePage(currentPage.copyWith(textBlocks: updated));
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

  void addInkStroke(List<InkPoint> points) {
    if (points.isEmpty) {
      return;
    }
    final baseWidth = tool == DrawingTool.highlighter
      ? inkStrokeWidth * 8.0
        : inkStrokeWidth;
    final stroke = InkStroke(
      id: _uuid.v4(),
      points: points,
      color: inkColor,
      width: baseWidth,
      tool: tool,
    );
    _applyAction(AddInkStrokeAction(stroke));
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
